#!/usr/bin/env python3
"""Syntax-level validation for every Swift file in ios/Paperico using tree-sitter.

This cannot type-check SwiftUI (no Apple toolchain on Linux), but it catches
brace/paren/keyword-level syntax errors before the project is opened in Xcode.

Usage: python3 scripts/check_swift_syntax.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import tree_sitter_swift
from tree_sitter import Language, Parser

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT / "Paperico"

SWIFT = Language(tree_sitter_swift.language())


def main() -> int:
    parser = Parser(SWIFT)
    failures: list[tuple[Path, list[str]]] = []
    files = sorted(SOURCE_DIR.rglob("*.swift"))

    for path in files:
        source = path.read_bytes()
        tree = parser.parse(source)
        errors: list[str] = []

        def walk(node) -> None:  # noqa: ANN001
            if node.type == "ERROR" or node.is_missing:
                line = source[: node.start_byte].count(b"\n") + 1
                snippet = source[node.start_byte : node.start_byte + 60].decode("utf-8", "replace")
                errors.append(f"  line {line}: [{node.type}] {snippet!r}")
            for child in node.children:
                walk(child)

        walk(tree.root_node)
        if errors:
            failures.append((path, errors))

    print(f"checked {len(files)} files")
    for path, errors in failures:
        print(f"FAIL {path.relative_to(ROOT)}")
        for error in errors[:12]:
            print(error)
    if not failures:
        print("ALL OK")
        return 0
    print(f"{len(failures)} file(s) with syntax errors")
    return 1


if __name__ == "__main__":
    sys.exit(main())
