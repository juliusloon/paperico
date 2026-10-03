#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify|--build-only) ;;
  *) echo "Usage: $0 [--debug|--logs|--telemetry|--verify|--build-only]" >&2; exit 2 ;;
esac

PAPERICO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]] \
   && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

PAPERICO_CONFIGURATION="${PAPERICO_CONFIGURATION:-Debug}"
case "$PAPERICO_CONFIGURATION" in
  Debug|Release) ;;
  *) echo "PAPERICO_CONFIGURATION must be Debug or Release." >&2; exit 2 ;;
esac
PAPERICO_DERIVED="${PAPERICO_DERIVED_DATA:-$PAPERICO_ROOT/macos/build/DerivedData-Local}"
PAPERICO_APP="$PAPERICO_DERIVED/Build/Products/$PAPERICO_CONFIGURATION/Paperico.app"
PAPERICO_LOG="$PAPERICO_ROOT/macos/build/build-local.log"
mkdir -p "$(dirname "$PAPERICO_LOG")"

if [ "$MODE" != "--build-only" ]; then pkill -x Paperico >/dev/null 2>&1 || true; fi
if ! xcodebuild -project "$PAPERICO_ROOT/macos/Paperico.xcodeproj" -scheme Paperico \
  -configuration "$PAPERICO_CONFIGURATION" -destination 'platform=macOS' -derivedDataPath "$PAPERICO_DERIVED" \
  build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= > "$PAPERICO_LOG" 2>&1; then
  tail -n 60 "$PAPERICO_LOG" >&2
  exit 1
fi
echo "Built: $PAPERICO_APP"

case "$MODE" in
  --build-only) exit 0 ;;
  --debug) lldb -- "$PAPERICO_APP/Contents/MacOS/Paperico" ;;
  run) /usr/bin/open -n "$PAPERICO_APP" ;;
  --verify)
    /usr/bin/open -n "$PAPERICO_APP"
    sleep 2
    pgrep -x Paperico >/dev/null
    echo "Paperico is running."
    ;;
  --logs)
    /usr/bin/open -n "$PAPERICO_APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "Paperico"'
    ;;
  --telemetry)
    /usr/bin/open -n "$PAPERICO_APP"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.paperico.native"'
    ;;
esac
