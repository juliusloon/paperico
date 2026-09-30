#!/bin/bash
# Full-module type check for the SwiftUI target WITHOUT needing the Swift macro
# plugin server.
#
# Why this exists
# ---------------
# On some machines the toolchain cannot launch `swift-plugin-server`
# (nested `sandbox_apply` is denied → "malformed response" → every `@State` /
# `@Observable` fails to expand), so `xcodebuild` cannot build ANY change even
# though the code is fine. `@State` and `@Observable` are the only macro-based
# constructs this project uses; everything else type-checks natively.
#
# This script copies the sources to a scratch directory and swaps in type-level
# stand-ins:
#   @State       → CheckState        (DynamicProperty w/ nonmutating set + Binding)
#   @Observable  → `: Observable`    (keeps `@Environment(SomeStore.self)` valid)
# then runs `swiftc -typecheck` over the whole module. Storage semantics differ,
# but every signature, symbol and call site really is checked.
#
# Usage: ./scripts/typecheck_no_macros.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d)/src"

cleanup() { rm -rf "$(dirname "$WORK")"; }
trap cleanup EXIT

mkdir -p "$WORK"
cp -R "$ROOT/Paperico/." "$WORK/"

cat > "$WORK/CheckShim.swift" <<'SWIFT'
import SwiftUI

@propertyWrapper
struct CheckState<Value>: DynamicProperty {
    private final class Box {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let box: Box

    init(wrappedValue: Value) { box = Box(wrappedValue) }
    init(initialValue: Value) { box = Box(initialValue) }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
SWIFT

python3 - "$WORK" <<'PY'
import pathlib, re, sys
ROOT = pathlib.Path(sys.argv[1])
CLASS_RE = re.compile(r'^(\s*)(?:public\s+|internal\s+)?final\s+class\s+(\w+)([^\n]*?)\{\s*$')
n = 0
for p in sorted(ROOT.rglob('*.swift')):
    if p.name == 'CheckShim.swift':
        continue
    out = p.read_text().replace('@State ', '@CheckState ')
    lines = out.split('\n')
    for i, line in enumerate(lines):
        if line.strip() != '@Observable':
            continue
        j = i + 1
        while j < len(lines) and lines[j].strip() == '':
            j += 1
        m = CLASS_RE.match(lines[j]) if j < len(lines) else None
        if not m:
            print('WARN: unhandled @Observable at %s:%d' % (p, i + 1))
            continue
        indent, name, rest = m.groups()
        rest = rest.strip()
        new_rest = ':' + rest[1:].strip() + ', Observable' if rest.startswith(':') else ': Observable'
        lines[j] = f'{indent}final class {name}{new_rest} {{'
        lines[i] = ''
        n += 1
    p.write_text('\n'.join(lines))
print('rewrote %d @Observable classes' % n)
PY

echo "type-checking $(cd "$WORK" && ls -d *.swift App/**/*.swift 2>/dev/null | wc -l | tr -d ' ') files ..."
cd "$WORK"
find . -name "*.swift" -print0 | xargs -0 xcrun --sdk macosx swiftc -swift-version 5 -typecheck 2>&1 | grep -E "error:|warning:" | grep -v "was never mutated" || true

COUNT=$(find . -name "*.swift" -print0 | xargs -0 xcrun --sdk macosx swiftc -swift-version 5 -typecheck 2>&1 | grep -cE "error:" || true)
if [[ "$COUNT" == "0" ]]; then
  echo "✅ type check passed (0 errors) — note: @State/@Observable were shimmed."
else
  echo "❌ $COUNT error(s)"
  exit 1
fi
