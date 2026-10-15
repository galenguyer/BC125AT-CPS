#!/bin/bash
# Builds a release of BC125AT CPS (SPEC.md §6.3) from a clean checkout of HEAD, so uncommitted
# changes never reach a release:
#   1. runs the BC125ATKit tests,
#   2. archives the app (Release) and signs it with a Developer ID,
#   3. checks the signature and entitlements,
#   4. zips the app and the bc125at-cli tool into dist/, notarizes both, staples the app,
#      and writes SHA-256 checksums.
#
# DEVELOPER_ID="Developer ID Application: Name (TEAMID)" picks the certificate; without it, the
# first Developer ID Application identity in the keychain is used. Notarization needs either
#   NOTARY_PROFILE=<keychain profile created with `xcrun notarytool store-credentials`>
# or an App Store Connect API key (what .github/workflows/release.yml uses):
#   NOTARY_KEY=<path to AuthKey_XXXX.p8>  NOTARY_KEY_ID=<key ID>  NOTARY_ISSUER=<issuer ID>
# scripts/release-unsigned.sh builds the same thing signed ad hoc and not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${UNSIGNED:-}" ]]; then
    DEVELOPER_ID=""
    NOTARY_ARGS=()
else
    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        DEVELOPER_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
        [[ -n "$DEVELOPER_ID" ]] || { echo "error: no Developer ID Application identity in the keychain; set DEVELOPER_ID or use scripts/release-unsigned.sh" >&2; exit 1; }
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${NOTARY_KEY:-}" ]]; then
        NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    else
        echo "error: set NOTARY_PROFILE or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER to notarize, or use scripts/release-unsigned.sh" >&2
        exit 1
    fi
fi

PROJECT="BC125AT CPS.xcodeproj"
SCHEME="BC125AT CPS"
WORK="build/release"
SRC="$WORK/src"

# Check out HEAD into its own worktree and build from there.
git worktree remove --force "$SRC" 2>/dev/null || true
rm -rf "$WORK"
git worktree prune
mkdir -p "$WORK" dist
if [[ -n "$(git status --porcelain)" ]]; then
    echo "note: building HEAD ($(git rev-parse --short HEAD)); uncommitted changes are not included"
fi
git worktree add --quiet --detach "$SRC" HEAD
trap 'git worktree remove --force "$SRC"' EXIT

VERSION=$(xcodebuild -project "$SRC/$PROJECT" -target "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk '/^ *MARKETING_VERSION = / { print $3 }')
APP_ZIP="dist/BC125AT-CPS-$VERSION.zip"
CLI_ZIP="dist/bc125at-cli-$VERSION-macos.zip"

echo "==> BC125AT CPS $VERSION (${DEVELOPER_ID:-ad hoc})"

echo "==> Testing BC125ATKit"
(cd "$SRC/BC125ATKit" && swift test --quiet)

echo "==> Archiving the app"
xcodebuild -project "$SRC/$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$WORK/BC125AT CPS.xcarchive" -derivedDataPath "$WORK/DerivedData" \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    archive -quiet
APP="$WORK/BC125AT CPS.xcarchive/Products/Applications/BC125AT CPS.app"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "==> Signing with $DEVELOPER_ID"
    codesign --force --options runtime --timestamp --entitlements "$SRC/App/BC125ATCPS.entitlements" \
        --sign "$DEVELOPER_ID" "$APP"
fi

echo "==> Checking the signature"
codesign --verify --strict --verbose=1 "$APP"
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
for key in com.apple.security.app-sandbox com.apple.security.device.usb com.apple.security.files.user-selected.read-write com.apple.security.network.client; do
    grep -q "$key" <<<"$ENTITLEMENTS" || { echo "error: missing entitlement $key" >&2; exit 1; }
done
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Signature|CodeDirectory)"

echo "==> Building bc125at-cli"
(cd "$SRC/BC125ATKit" && swift build -c release --product bc125at-cli --arch arm64 --arch x86_64 --quiet)
CLI=$(cd "$SRC/BC125ATKit" && swift build -c release --product bc125at-cli --arch arm64 --arch x86_64 --show-bin-path)/bc125at-cli
codesign --force --sign "${DEVELOPER_ID:--}" ${DEVELOPER_ID:+--options runtime --timestamp} "$CLI"

echo "==> Packaging"
rm -f "$APP_ZIP" "$CLI_ZIP"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
ditto -c -k "$CLI" "$CLI_ZIP"

# notarytool can exit 0 for a rejected submission, so check the status it reports.
notarize() {
    local out
    out=$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait 2>&1) || true
    echo "$out"
    if ! grep -q "status: Accepted" <<<"$out"; then
        local id
        id=$(awk '/^ *id: / { print $2; exit }' <<<"$out")
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" || true
        echo "error: notarization of $1 failed" >&2
        exit 1
    fi
}
if [[ -n "$DEVELOPER_ID" ]]; then
    echo "==> Notarizing"
    notarize "$APP_ZIP"
    # A bare executable can't be stapled; Gatekeeper looks its ticket up online instead.
    notarize "$CLI_ZIP"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
fi

(cd dist && shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$CLI_ZIP")" > "SHA256SUMS-$VERSION.txt")
echo "==> Done"
ls -lh "$APP_ZIP" "$CLI_ZIP"
cat "dist/SHA256SUMS-$VERSION.txt"
