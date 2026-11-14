#!/usr/bin/env bash
# Packages build/Figg.app (made by scripts/bundle.sh) into build/figg-<version>.dmg.
#
#   FIGG_VERSION=0.2.0 scripts/dmg.sh
#
# Unsigned by default (the app keeps whatever signature bundle.sh gave it).
# With credentials it signs and notarizes:
#   FIGG_SIGN_IDENTITY    Developer ID Application identity; re-signs the app
#                         with a secure timestamp and signs the DMG
#   FIGG_NOTARY_PROFILE   notarytool keychain profile (local use), or
#   FIGG_NOTARY_APPLE_ID / FIGG_NOTARY_PASSWORD / FIGG_NOTARY_TEAM_ID (CI)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${FIGG_VERSION:?Set FIGG_VERSION, e.g. FIGG_VERSION=0.2.0}"
APP="build/Figg.app"
[[ -d "$APP" ]] || { echo "No $APP; run scripts/bundle.sh first" >&2; exit 1; }

# Notarization requires a secure timestamp, which bundle.sh omits.
if [[ -n "${FIGG_SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp \
    --entitlements Resources/Figg.entitlements \
    --sign "$FIGG_SIGN_IDENTITY" "$APP"
fi

DMG="build/figg-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "figg" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ -n "${FIGG_SIGN_IDENTITY:-}" ]]; then
  codesign --sign "$FIGG_SIGN_IDENTITY" --timestamp "$DMG"
  if [[ -n "${FIGG_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$FIGG_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  elif [[ -n "${FIGG_NOTARY_APPLE_ID:-}" ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$FIGG_NOTARY_APPLE_ID" \
      --password "$FIGG_NOTARY_PASSWORD" --team-id "$FIGG_NOTARY_TEAM_ID" --wait
    xcrun stapler staple "$DMG"
  else
    echo "Signed but not notarized: set FIGG_NOTARY_PROFILE or FIGG_NOTARY_APPLE_ID" >&2
  fi
fi

echo "DMG ready: $DMG"
