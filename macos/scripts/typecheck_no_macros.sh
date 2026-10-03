#!/usr/bin/env bash
# Compatibility entrypoint. Macro stand-ins cannot establish that a SwiftUI app
# builds or starts; keep callers on the real Xcode build used by the Run action.
set -euo pipefail
PAPERICO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$PAPERICO_ROOT/script/build_and_run.sh" --build-only
