#!/usr/bin/env bash
set -euo pipefail
PAPERICO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]] \
   && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
PAPERICO_PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PAPERICO_PROBE_DIR"' EXIT
cd "$PAPERICO_ROOT"
xcrun swiftc -parse-as-library -o "$PAPERICO_PROBE_DIR/MarkdownRenderingSmoke" \
  macos/Tests/MarkdownRenderingSmoke.swift \
  macos/Paperico/Core/MarkdownTable.swift \
  macos/Paperico/Components/MarkdownText.swift \
  macos/Paperico/Components/GlassKit.swift \
  macos/Paperico/App/Theme.swift \
  macos/Paperico/App/WindowChrome.swift \
  macos/Paperico/Support/PaperMarkdown.swift \
  macos/Paperico/Support/ReaderPerf.swift \
  macos/Paperico/Support/AppPaths.swift
"$PAPERICO_PROBE_DIR/MarkdownRenderingSmoke"
