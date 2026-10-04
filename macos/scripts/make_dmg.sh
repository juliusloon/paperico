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
  -derivedDataPath "$DERIVED" clean build "$@"

# Reject missing or mismatched icons before distributing the app.
python3 - "$APP" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
source = Path("Paperico/paperico.icon")
document = json.loads((source / "icon.json").read_text())
for group in document["groups"]:
    for layer in group["layers"]:
        if "image-name" in layer:
            assert (source / "Assets" / layer["image-name"]).is_file(), layer
with (app / "Contents/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info.get("CFBundleIconName") == "paperico", info.get("CFBundleIconName")
assert info.get("CFBundleIconFile") in ("paperico", "paperico.icns")
for name in ("paperico.icns", "Assets.car"):
    resource = app / "Contents/Resources" / name
    assert resource.is_file() and resource.stat().st_size > 0, resource
print("Validated compiled Paperico icon resources.")
PY

if [ -n "${PAPERICO_SIGN_IDENTITY:-}" ]; then
  echo "Signing with '$PAPERICO_SIGN_IDENTITY'…"
  codesign --force --options runtime --entitlements Paperico/Support/Paperico.entitlements \
    --sign "$PAPERICO_SIGN_IDENTITY" "$APP"
else
  # Even unsigned CI builds must retain App Sandbox and localhost MCP entitlements.
  codesign --force --entitlements Paperico/Support/Paperico.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"
python3 - "$APP" "$VERSION" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
with (app / "Contents/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleShortVersionString"] == sys.argv[2], info
signature = subprocess.run(
    ["codesign", "-d", "--entitlements", ":-", str(app)],
    capture_output=True, check=True,
)
entitlements = plistlib.loads(signature.stdout)
for key in ("com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.network.server"):
    assert entitlements.get(key) is True, (key, entitlements)
assert (app / "Contents/Resources/Resources/MCP-LICENSES.txt").is_file()
print("Validated release version, Sandbox/MCP entitlements and bundled licenses.")
PY

echo "Packaging DMG…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Paperico $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
python3 - "$DMG" <<'PY'
import hashlib
import sys
from pathlib import Path
image = Path(sys.argv[1])
digest = hashlib.sha256(image.read_bytes()).hexdigest()
image.with_suffix(image.suffix + ".sha256").write_text(f"{digest}  {image.name}\n")
PY

echo "DMG ready: $DMG"
