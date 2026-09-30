#!/bin/bash
# Compiles the reading-page hot path (real app sources, no Swift macros involved)
# into a CLI benchmark and runs it against a real GET /api/papers/{id} payload.
#
# Usage:
#   ./scripts/run_reader_bench.sh                         # uses today's cached payload or fetches one
#   ./scripts/run_reader_bench.sh /tmp/detail_xxx.json    # explicit payload
#
# Why not measure inside the app? See docs/macos-window-and-reader-perf.md
# (this machine's toolchain cannot expand Swift macros, so the full target
# cannot be built here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${TMPDIR:-/tmp}/paperico_readerbench"
PAYLOAD="${1:-}"

BACKEND="${PAPERICO_BACKEND:-http://127.0.0.1:8000}"

if [[ -z "$PAYLOAD" ]]; then
  PAPER_ID=$(curl -s "$BACKEND/api/papers" | python3 -c '
import json, sys
papers = json.load(sys.stdin)
if isinstance(papers, dict):
    papers = papers.get("items", [])
print(papers[0]["id"] if papers else "")
')
  if [[ -z "$PAPER_ID" ]]; then
    echo "无法从 $BACKEND/api/papers 取到论文,请手动传入 payload 路径。" >&2
    exit 1
  fi
  PAYLOAD="$OUT-detail.json"
  echo "拉取论文 $PAPER_ID ..."
  curl -s "$BACKEND/api/papers/$PAPER_ID" -o "$PAYLOAD"
fi

echo "编译基准测试(真实源码)..."
DEVELOPER_DIR="${DEVELOPER_DIR:-}"
if [[ -z "$DEVELOPER_DIR" && -d /Applications/Xcode.app ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --sdk macosx swiftc -O \
  "$ROOT/Paperico/Support/PaperMarkdown.swift" \
  "$ROOT/Paperico/Support/ReaderPerf.swift" \
  "$ROOT/Paperico/Components/MarkdownText.swift" \
  "$ROOT/Paperico/App/Theme.swift" \
  "$ROOT/Paperico/Models/Models.swift" \
  "$SCRIPT_DIR/reader_perf_bench.swift" \
  -o "$OUT" 2>&1 | grep -v "was never mutated" | grep -v "^ *|" | grep -v "^-" || true

echo "运行:$PAYLOAD"
"$OUT" "$PAYLOAD"
