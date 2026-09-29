#!/usr/bin/env python3
"""Anti-drift contract check between the paperico backend and the native app.

Implements the agentero-lessons §5 recommendation ("OpenAPI 快照测试") on the
client side: pull the backend's /openapi.json (or read a saved copy) and compare
the fields of every schema the Swift `Models.swift` mirror against an embedded
snapshot. Any added / removed / renamed field breaks the check so the Swift
models get updated in the same change.

Usage:
  python3 scripts/check_api_contract.py --base http://127.0.0.1:8000
  python3 scripts/check_api_contract.py --file openapi.json
  python3 scripts/check_api_contract.py --file openapi.json --update   # refresh snapshot
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

# Field sets the Swift Codable structs in ios/Paperico/Models/Models.swift rely on.
# Keys are components.schemas names in the FastAPI OpenAPI document.
SNAPSHOT: dict[str, set[str]] = {
    "ProjectOut": {"id", "name", "description", "color_tag", "paper_count", "created_at"},
    "PaperListItem": {
        "id", "title", "title_zh", "authors", "year", "domain_tags", "status",
        "project_id", "source_type", "original_file_name", "created_at",
        "last_opened_at", "tldr", "narrative_summary", "contributions",
        "difficulty_estimate", "venue", "error_message", "error_code",
    },
    "BlockOut": {
        "id", "order", "kind", "page_idx", "bbox", "section_title", "text_original",
        "text_zh", "one_liner", "keywords", "role_in_narrative", "image_path",
        "caption_original", "caption_zh", "figure_type", "core_takeaways",
        "data_reading_notes", "table_html", "latex", "plain_explanation", "entity_refs",
    },
    "EntityOut": {"id", "canonical_key", "name", "category", "definition_zh", "block_refs"},
    "PaperDetail": {"paper", "blocks", "entities"},
    "PaperStatusOut": {"id", "status", "error_message", "error_code"},
    "ChatMessageOut": {"id", "session_id", "role", "content", "attached_context", "cited_block_ids", "created_at"},
    "ChatSessionOut": {"id", "paper_id", "title", "messages", "created_at"},
    "NoteOut": {"id", "paper_id", "title", "markdown_content", "created_at", "updated_at"},
    "ModelProfileOut": {
        "id", "name", "base_url", "api_key_masked", "api_key_configured", "model",
        "temperature", "max_tokens", "reasoning_effort", "streaming",
    },
    "AppearanceSettings": {"accent_color", "theme_mode", "reading_font_size", "bilingual_layout"},
    "ChatDefaults": {"preset_prompts", "target_language", "enable_wikilinks"},
    "MethodIndexItem": {"canonical_key", "name", "category", "definition_zh", "papers"},
}

SNAPSHOT_FIELDS = {"model_profiles", "profile_assignment", "mineru", "appearance", "chat_defaults"}


def load_openapi(args: argparse.Namespace) -> dict:
    if args.file:
        return json.loads(Path(args.file).read_text(encoding="utf-8"))
    url = args.base.rstrip("/") + "/openapi.json"
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def schema_fields(schema: dict, components: dict) -> set[str]:
    """Resolve the top-level properties of a schema, following $ref chains."""
    if "$ref" in schema:
        name = schema["$ref"].split("/")[-1]
        return schema_fields(components["schemas"][name], components)
    if "allOf" in schema:
        fields: set[str] = set()
        for sub in schema["allOf"]:
            fields |= schema_fields(sub, components)
        fields |= set(schema.get("properties", {}))
        return fields
    return set(schema.get("properties", {}))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8000", help="backend base URL")
    parser.add_argument("--file", help="read openapi.json from disk instead of --base")
    parser.add_argument("--update", action="store_true", help="print the snapshot to paste back")
    args = parser.parse_args()

    document = load_openapi(args)
    components = document.get("components", {})
    schemas = components.get("schemas", {})

    problems: list[str] = []
    for name, expected in SNAPSHOT.items():
        if name not in schemas:
            problems.append(f"{name}: schema missing from backend OpenAPI")
            continue
        actual = schema_fields(schemas[name], components)
        removed = expected - actual
        added = actual - expected
        if removed:
            problems.append(f"{name}: fields REMOVED from backend (update Models.swift): {sorted(removed)}")
        if added:
            problems.append(f"{name}: fields ADDED on backend (mirror in Models.swift or extend snapshot): {sorted(added)}")

    # AppSettingsOut is referenced via AppSettingsUpdate; check its parts through
    # any schema that carries the five top-level settings keys.
    for name, schema in schemas.items():
        fields = schema_fields(schema, components)
        if SNAPSHOT_FIELDS <= fields:
            removed = SNAPSHOT_FIELDS - fields
            added = fields - SNAPSHOT_FIELDS
            if removed:
                problems.append(f"{name}: settings keys REMOVED: {sorted(removed)}")
            if added:
                problems.append(f"{name}: settings keys ADDED on backend: {sorted(added)}")
            break

    if args.update:
        print(json.dumps({k: sorted(v) for k, v in SNAPSHOT.items()}, indent=2, ensure_ascii=False))
        return 0

    if problems:
        print("API CONTRACT DRIFT DETECTED:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(f"contract OK: {len(SNAPSHOT)} schemas match the native app snapshot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
