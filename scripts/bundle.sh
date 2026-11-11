#!/usr/bin/env bash
# Builds figg and wraps the binary in build/Figg.app.
#
#   scripts/bundle.sh            # release build, ad-hoc signed (runs on this Mac)
#   FIGG_SIGN_IDENTITY="Developer ID Application: ..." scripts/bundle.sh
#   FIGG_CONFIG=Debug scripts/bundle.sh
#
# Builds with xcodebuild rather than `swift build`: SwiftPM's own resource
# accessor only looks for resource bundles at the .app root (which codesign
# rejects), while Xcode's also checks Contents/Resources.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${FIGG_CONFIG:-Release}"
# Default to the latest tag so local builds don't think they're outdated
# (the updater compares this against the published latest.json). CI sets FIGG_VERSION.
TAG_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
VERSION="${FIGG_VERSION:-${TAG_VERSION#v}}"
VERSION="${VERSION:-0.1.0}"
BUILD="${FIGG_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# A stable identity keeps macOS privacy permissions (mic, system audio) across
# rebuilds. Ad-hoc signing ("-") ties them to one exact build, so every
# rebuild has to be re-approved. Create "figg Local Signing" once with
# docs/local-signing.md, or set FIGG_SIGN_IDENTITY.
if [[ -z "${FIGG_SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"figg Local Signing"'; then
  FIGG_SIGN_IDENTITY="figg Local Signing"
fi
IDENTITY="${FIGG_SIGN_IDENTITY:--}"
APP="build/Figg.app"

xcodebuild -scheme Figg -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation -quiet build
BIN=".build/xcode/Build/Products/$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Figg" "$APP/Contents/MacOS/Figg"
# Package resource bundles (GRDB, swift-crypto, swift-transformers).
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
# Icons; regenerate from Resources/figg-logo.png with: swift scripts/make-icon.swift
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --deep --options runtime --timestamp=none \
  --entitlements Resources/Figg.entitlements \
  --sign "$IDENTITY" "$APP"

echo "Built $APP ($VERSION build $BUILD, signed with '$IDENTITY')"
