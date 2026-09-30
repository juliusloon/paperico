#!/bin/bash
# Build a distributable Paperico-<version>.dmg (Release configuration).
#
# Usage: scripts/make_dmg.sh [extra xcodebuild settings...]
#   e.g. CODE_SIGNING_ALLOWED=NO for CI, or set PAPERICO_SIGN_IDENTITY to
#   codesign with a Developer ID before packaging:
#     PAPERICO_SIGN_IDENTITY="Developer ID Application: …" scripts/make_dmg.sh
#
# Output: build/Paperico-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

# xcodebuild needs full Xcode; if only Command Line Tools are selected, point
# DEVELOPER_DIR at the installed Xcode for this run (no sudo xcode-select).
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]] \
   && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' Paperico.xcodeproj/project.pbxproj | grep -o '[0-9.]*')
DERIVED=build/DerivedData-Release
APP="$DERIVED/Build/Products/Release/Paperico.app"
STAGE=build/dmg
DMG="build/Paperico-$VERSION.dmg"

echo "Building Paperico $VERSION (Release)…"
xcodebuild -project Paperico.xcodeproj -scheme Paperico \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" build "$@"

if [ -n "${PAPERICO_SIGN_IDENTITY:-}" ]; then
  echo "Signing with '$PAPERICO_SIGN_IDENTITY'…"
  codesign --deep --force --options runtime --sign "$PAPERICO_SIGN_IDENTITY" "$APP"
fi

echo "Packaging DMG…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Paperico $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "DMG ready: $DMG"
