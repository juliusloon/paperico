#!/bin/bash
# Compiles the reading-page hot path (real app sources, no Swift macros involved)
# into a CLI benchmark and runs it against a real GET /api/papers/{id} payload.
#
# Usage:
#   ./scripts/run_reader_bench.sh                         # uses today's cached payload or fetches one
#   ./scripts/run_reader_bench.sh /tmp/detail_xxx.json    # explicit payload
#
# This measures the historical native Markdown renderer in isolation.
# The current offline WKWebView document surface requires separate measurement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paperico_readerbench.XXXXXX")"
OUT="$RUN_DIR/readerbench"
trap 'rm -rf -- "$RUN_DIR"' EXIT
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
  PAYLOAD="$RUN_DIR/detail.json"
  echo "拉取论文 $PAPER_ID ..."
  curl -s "$BACKEND/api/papers/$PAPER_ID" -o "$PAYLOAD"
fi

echo "编译基准测试(真实源码)..."
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools \
      && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif [[ -n "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR
fi
xcrun --sdk macosx swiftc -O \
  -module-cache-path "$RUN_DIR/module-cache" \
  "$ROOT/Paperico/Support/AppPaths.swift" \
  "$ROOT/Paperico/Support/PaperMarkdown.swift" \
  "$ROOT/Paperico/Support/ReaderPerf.swift" \
  "$ROOT/Paperico/Components/MarkdownText.swift" \
  "$ROOT/Paperico/Components/CitationInlineText.swift" \
  "$ROOT/Paperico/Components/GlassKit.swift" \
  "$ROOT/Paperico/Core/ChatContextBuilder.swift" \
  "$ROOT/Paperico/Core/MarkdownTable.swift" \
  "$ROOT/Paperico/Core/MethodGroup.swift" \
  "$ROOT/Paperico/Core/ServiceErrors.swift" \
  "$ROOT/Paperico/App/Theme.swift" \
  "$ROOT/Paperico/App/WindowChrome.swift" \
  "$ROOT/Paperico/Models/PaperStatus.swift" \
  "$ROOT/Paperico/Models/Models.swift" \
  "$SCRIPT_DIR/reader_perf_bench.swift" \
  -o "$OUT"

echo "运行:$PAYLOAD"
"$OUT" "$PAYLOAD"
