"""Layered, budgeted chat context assembly (agentero plan T2.2).

Replaces the hard ``[:3000]`` / ``[:2000]`` character slices in the chat
system prompt. Truncation now happens only on whole semantic lines, section
headings survive regardless of where they sit in the paper, and the later
parts of a long paper can no longer silently vanish mid-line from the prompt.

Line shapes:
  logic chain   ``角色 · [b00xx] 一句话；[b00xx] 一句话``  (adjacent same-role
                blocks merged onto one line; section headings always get their
                own ``§ [b00xx] 标题`` line and are never dropped)
  method index  ``Name(CATEGORY) → [b00xx,b00yy]``  (entities ranked by how
                many blocks mention them, Top-K only)
"""

from __future__ import annotations

LOGIC_CHAIN_BUDGET = 6000  # characters, whole lines only
ONE_LINER_LIMIT = 120
METHOD_INDEX_TOP_K = 40
METHOD_INDEX_REF_LIMIT = 12
SELECTION_SNIPPET_LIMIT = 240
FIGURE_SUMMARY_LIMIT = 400


def clip_text(value: str | None, limit: int) -> str:
    """Trim to ``limit`` characters on a whole-value basis (never mid-word
    guarantees — the ellipsis marks the cut explicitly)."""
    text = ("" if value is None else str(value)).strip()
    if len(text) <= limit:
        return text
    return text[:limit].rstrip() + "…"


def _field(block, name: str, default: str = "") -> str:
    value = block.get(name, default) if isinstance(block, dict) else getattr(block, name, default)
    return value if isinstance(value, str) else ("" if value is None else str(value))


def compact_logic_chain(blocks, budget: int = LOGIC_CHAIN_BUDGET) -> str:
    """Compress the paper's blocks into role-grouped, budgeted lines.

    Over-budget discard order: the tail-most non-heading line first, whole
    lines only. Section headings are kept unconditionally — they are the
    structural anchors the model navigates by (if headings alone exceed the
    budget, the budget yields; that case is practically unreachable).
    """
    entries: list[tuple[bool, str]] = []  # (is_heading, line)
    group_refs: list[str] = []
    group_role = ""

    def flush_group() -> None:
        nonlocal group_refs, group_role
        if group_refs:
            entries.append((False, f"{group_role or '内容'} · {'；'.join(group_refs)}"))
            group_refs = []
            group_role = ""

    for block in blocks:
        kind = _field(block, "kind")
        block_id = _field(block, "id")
        one_liner = clip_text(_field(block, "one_liner"), ONE_LINER_LIMIT)
        if kind == "section_heading":
            flush_group()
            title = clip_text(
                _field(block, "text_original") or _field(block, "section_title") or one_liner,
                ONE_LINER_LIMIT,
            )
            entries.append((True, f"§ [{block_id}] {title}"))
            continue
        if not one_liner:
            continue
        role = _field(block, "role_in_narrative") or "内容"
        if role != group_role:
            flush_group()
            group_role = role
        group_refs.append(f"[{block_id}] {one_liner}")
    flush_group()

    def total_length() -> int:
        return sum(len(line) + 1 for _, line in entries)

    while total_length() > budget:
        tail = next(
            (index for index in range(len(entries) - 1, -1, -1) if not entries[index][0]),
            None,
        )
        if tail is None:
            break  # only headings left; keep them all
        del entries[tail]
    return "\n".join(line for _, line in entries)


def compact_method_index(entities, top_k: int = METHOD_INDEX_TOP_K) -> str:
    """Rank entities by mention count and render ``name(category) → [refs]``."""
    ranked = sorted(
        entities,
        key=lambda entity: -len(_refs(entity)),
    )[:top_k]
    lines = []
    for entity in ranked:
        refs = _refs(entity)
        shown = refs[:METHOD_INDEX_REF_LIMIT]
        overflow = f"…(+{len(refs) - len(shown)})" if len(refs) > len(shown) else ""
        name = _field(entity, "name") or "?"
        category = _field(entity, "category") or "OTHER"
        lines.append(f"{name}({category}) → [{','.join(shown)}]{overflow}")
    return "\n".join(lines)


def _refs(entity) -> list[str]:
    value = entity.get("block_refs") if isinstance(entity, dict) else getattr(entity, "block_refs", None)
    if not isinstance(value, list):
        return []
    return [ref for ref in value if isinstance(ref, str) and ref]


def build_paper_context(blocks, entities) -> str:
    """Assemble the two labeled context sections for the chat system prompt."""
    return "\n\n".join((
        "【全文逻辑链（压缩版，按原文顺序）】\n" + compact_logic_chain(blocks),
        "【已识别方法/实体索引】\n" + compact_method_index(entities),
    ))
