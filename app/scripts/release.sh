#!/usr/bin/env bash
# Signed, notarized .dmg built locally. Needs an Apple Developer ID.
# Normal releases come from CI instead: merge the release-please PR and
# .github/workflows/release-please.yml builds and uploads the DMG.
#
#   FIGG_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   FIGG_NOTARY_PROFILE=figg-notary \
#   FIGG_VERSION=0.1.0 scripts/release.sh
#
# One-time notary setup (stores an app-specific password in the Keychain):
#   xcrun notarytool store-credentials figg-notary --apple-id you@example.com --team-id TEAMID
set -euo pipefail

cd "$(dirname "$0")/.."
: "${FIGG_SIGN_IDENTITY:?Set FIGG_SIGN_IDENTITY to a Developer ID Application identity}"
: "${FIGG_NOTARY_PROFILE:?Set FIGG_NOTARY_PROFILE to a notarytool keychain profile}"
VERSION="${FIGG_VERSION:-0.1.0}"

FIGG_VERSION="$VERSION" scripts/bundle.sh
FIGG_VERSION="$VERSION" scripts/dmg.sh
