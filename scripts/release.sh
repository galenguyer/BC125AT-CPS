#!/bin/bash
# Builds a release of BC125AT CPS (SPEC.md §6.3) from a clean checkout of HEAD, so uncommitted
# changes (such as a local signing team in project.pbxproj) never reach a release:
#   1. runs the BC125ATKit tests,
#   2. archives the app (Release) and signs it ad hoc,
#   3. checks the signature and entitlements,
#   4. zips the app and the bc125at-cli tool into dist/ with SHA-256 checksums.
#
# Releases are ad-hoc signed and not notarized until there's a paid Apple Developer account;
# see README.md for how users open them. To sign with a Developer ID and notarize instead, set:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<keychain profile created with `xcrun notarytool store-credentials`>
# That path isn't exercised yet, because there's no account to test it with.
set -euo pipefail
cd "$(dirname "$0")/.."

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

echo "==> BC125AT CPS $VERSION"

echo "==> Testing BC125ATKit"
(cd "$SRC/BC125ATKit" && swift test --quiet)

echo "==> Archiving the app"
xcodebuild -project "$SRC/$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$WORK/BC125AT CPS.xcarchive" -derivedDataPath "$WORK/DerivedData" \
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
for key in com.apple.security.app-sandbox com.apple.security.device.usb com.apple.security.files.user-selected.read-write; do
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

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
fi

(cd dist && shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$CLI_ZIP")" > "SHA256SUMS-$VERSION.txt")
echo "==> Done"
ls -lh "$APP_ZIP" "$CLI_ZIP"
cat "dist/SHA256SUMS-$VERSION.txt"
