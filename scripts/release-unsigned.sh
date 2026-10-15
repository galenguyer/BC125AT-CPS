#!/bin/bash
# Builds the same release as scripts/release.sh, but signed ad hoc and not notarized, for when
# there's no Developer ID certificate or notary credentials at hand. Gatekeeper rejects these
# builds until the user clicks Open Anyway in System Settings ▸ Privacy & Security.
set -euo pipefail
UNSIGNED=1 exec "$(dirname "$0")/release.sh" "$@"
