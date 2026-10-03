#!/usr/bin/env bash
set -euo pipefail
PAPERICO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PAPERICO_ROOT"
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]] \
   && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
python3 -m unittest discover -s macos/scripts/tests -p 'test_*.py'
swift test --package-path macos
./script/check_markdown_rendering.sh
./script/build_and_run.sh --build-only
if [ "${1:-}" = "--with-backend" ]; then
  cd backend
  .venv/bin/python -m pytest -q
  .venv/bin/python -m ruff check .
  .venv/bin/python ../macos/scripts/check_api_contract.py --file tests/openapi_snapshot.json
fi
