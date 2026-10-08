#!/usr/bin/env bash
# Opt-in production upload/parse/analysis acceptance on three real PDFs
# (three to five when PAPERICO_E2E_QUESTIONS selects a citation manifest).
set -euo pipefail
PAPERICO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
PAPERICO_CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/paperico-release-check.XXXXXX")
trap 'rm -rf "$PAPERICO_CHECK_BUILD"' EXIT
python3 - "$PAPERICO_ROOT" "$PAPERICO_CHECK_BUILD/verify-real-pipeline" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
root = Path(sys.argv[1])
package = json.loads(subprocess.check_output([
    "swift", "package", "--package-path", str(root / "macos"), "describe", "--type", "json"]))
target = next(t for t in package["targets"] if t["name"] == "PapericoCore")
base = root / "macos" / target["path"]
sources = [str(base / path) for path in target["sources"]]
sources += [str(root / "macos/Paperico" / path) for path in (
    "Core/PaperPipeline.swift", "Stores/SettingsStore.swift", "Stores/PapersStore.swift", "Support/LocalPrefs.swift")]
sources.append(str(root / "macos/scripts/VerifyRealPipeline.swift"))
sources.append(str(root / "macos/scripts/CitationAcceptance.swift"))
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-o", sys.argv[2], *sources], check=True)
PY
"$PAPERICO_CHECK_BUILD/verify-real-pipeline"
