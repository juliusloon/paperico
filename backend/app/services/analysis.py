"""Map-Reduce analysis engine for paper understanding.

Map phase: batch translate + one-liner + entity extraction per block group.
Reduce phase: logic chain + narrative summary from compressed representations.
Figure phase: multimodal figure/table analysis.
"""

import json
import re

from .llm import LLMClient

# ── Map Phase ─────────────────────────────────────────────

MAP_SYSTEM_PROMPT = """你是一名同时精通化学信息学（Cheminformatics）与机器学习的科研助理，正在协助用户逐段精读一篇英文学术论文。
你的任务：对给定的若干"文本块"，逐块完成下列四件事，只输出规定的JSON，不要输出任何其他文字。

对每个块输出：
1. translation：忠实、专业、流畅的简体中文翻译。专业术语首次出现时保留英文原词并括注中译，如"随机森林（Random Forest, RF）"。公式、变量名、化合物代号、数据集/数据库专名一律保留英文原文不译。
2. one_liner：一句话（不超过30个汉字）概括该块核心内容，用于左侧目录导航，要求具体可区分，避免"介绍了背景"这类空泛表述。
3. keywords：0-3个能代表该块内容的关键词。
4. entities：从该块中识别出的"核心方法/实体"提及，每个包含：
   - name：实体名称（有缩写则写"全称（缩写）"，如"Small-Angle X-ray Scattering (SAXS)"）
   - category：从["ML_MODEL","ALGORITHM","INSTRUMENT_METHOD","DATASET_BENCHMARK","METRIC","CHEMISTRY","SOFTWARE_TOOL","OTHER"]中选择最贴切的一个
   - mention_context：该实体在本块中出现的原文短句（≤20词），用于溯源

只对确有明确出现的方法/实体输出，不要臆造或过度泛化（例如不要把"machine learning"本身当作实体，除非全文并未指明具体模型）。

输出格式（严格JSON对象，results数组必须与输入块一一对应、顺序一致，不得省略任何block_id）：
{
  "results": [
   {
    "block_id": "b0001",
    "translation": "...",
    "one_liner": "...",
    "keywords": ["..."],
    "entities": [{"name": "...", "category": "ML_MODEL", "mention_context": "..."}]
   }
  ]
}"""


async def run_map_phase(
    llm: LLMClient,
    blocks: list[dict],
    paper_title_abstract: str = "",
    batch_size: int = 12,
    strict: bool = False,
    raw_log: list[dict] | None = None,
) -> list[dict]:
    """Process blocks in batches through the Map phase.
    Returns enriched blocks with translation, one_liner, keywords, entities.

    Providers occasionally truncate a large JSON response.  The old behavior
    treated that as a successful batch and silently stored empty translations
    for every block in it.  We keep valid items, retry the incomplete batch,
    and finally split only the missing items into smaller requests.  ``strict``
    is used by maintenance/retry flows to make an unresolved missing result a
    visible processing error instead of another partially translated paper.

    When ``raw_log`` is a list, every raw provider response (including retries
    and split recoveries) is appended to it as ``{block_ids, raw_response}``
    so the caller can persist a sidecar for zero-LLM-cost replays (T2.1).
    """
    all_results = []

    for i in range(0, len(blocks), batch_size):
        batch_data = _map_batch_data(blocks[i : i + batch_size], i)
        all_results.extend(
            await _run_map_batch(llm, batch_data, paper_title_abstract, raw_log=raw_log)
        )

    if strict:
        missing = [
            item["block_id"]
            for item in all_results
            if item.get("requires_translation") and (
                not item.get("translation", "").strip()
                    or (
                        item.get("requires_chinese")
                        and (
                            not _contains_chinese(item.get("translation", ""))
                            or not _contains_chinese(item.get("one_liner", ""))
                        )
                    )
            )
        ]
        if missing:
            sample = ", ".join(missing[:8])
            suffix = "…" if len(missing) > 8 else ""
            raise ValueError(f"仍有 {len(missing)} 个文本块未获得译文（{sample}{suffix}），请重试或检查模型配置")

    # These validation hints are internal and should not be persisted or
    # exposed to the API layer.
    for item in all_results:
        item.pop("requires_translation", None)
        item.pop("requires_chinese", None)

    return all_results


def _map_batch_data(blocks: list[dict], offset: int = 0) -> list[dict]:
    """Build the compact, stable payload sent to the Map model."""
    batch_data = []
    for index, block in enumerate(blocks):
        if block.get("kind") in ("figure", "table"):
            source = (
                block.get("caption_original", "")
                or block.get("text_original", "")
                or ""
            )
        else:
            source = (
                block.get("text_original", "")
                or block.get("caption_original", "")
                or block.get("latex", "")
                or ""
            )
        batch_data.append({
            "block_id": block.get("id", f"b{offset + index:04d}"),
            "kind": block.get("kind", "paragraph"),
            "text": source,
            "section_title": block.get("section_title", ""),
        })
    return batch_data


def _map_source_requires_translation(block: dict) -> bool:
    """Return whether a block contains source text that should be translated."""
    # A figure/table with only an image or structured table and no caption has
    # no textual source for the Map model.  It is not a missing translation.
    if block.get("kind") == "equation":
        # Equations are rendered from LaTeX directly; their optional plain
        # language explanation is produced by a separate figure/vision path.
        return False
    return bool(str(block.get("text", "") or "").strip())


def _normalize_map_result(block: dict, item: dict | None) -> dict:
    """Normalize one provider item while retaining an internal completeness flag."""
    item = item if isinstance(item, dict) else {}
    entities = item.get("entities", [])
    entities = [
        entity for entity in entities
        if isinstance(entity, dict)
        and isinstance(entity.get("name"), str)
        and entity.get("name", "").strip()
    ] if isinstance(entities, list) else []
    keywords = item.get("keywords", [])
    translation = item.get("translation", "")
    one_liner = item.get("one_liner", "")
    return {
        "block_id": block["block_id"],
        "translation": translation.strip() if isinstance(translation, str) else "",
        "one_liner": one_liner.strip() if isinstance(one_liner, str) else "",
        "keywords": [str(value) for value in keywords if isinstance(value, (str, int, float))][:3]
        if isinstance(keywords, list) else [],
        "entities": entities,
        "requires_translation": _map_source_requires_translation(block),
        # Short section headings frequently contain a model/protocol name
        # (for example, "4.1.2 Mid-Mapper") that is intentionally kept in
        # English.  They still need a non-empty display value, but should not
        # make an otherwise complete paper fail the whole retry merely
        # because the proper name has no Chinese characters.
        "requires_chinese": _map_requires_chinese(block),
    }


def _map_result_needs_retry(block: dict, result: dict) -> bool:
    """Check the two fields that drive visible reader completeness."""
    if not result.get("requires_translation"):
        return False
    translation = result.get("translation", "")
    one_liner = result.get("one_liner", "")
    if not translation or not one_liner:
        return True
    # A provider can return the requested JSON while echoing English content.
    # For source blocks containing alphabetic text, retry until both visible
    # fields contain at least some Chinese characters.
    if result.get("requires_chinese"):
        return not _contains_chinese(translation) or not _contains_chinese(one_liner)
    return False


def _map_requires_chinese(block: dict) -> bool:
    """Whether visible Map fields should contain Chinese characters.

    Section headings are often proper names, model names, or numbered labels;
    preserving those tokens is preferable to rejecting a complete batch.  A
    heading is still retried when either visible field is empty.
    """
    if block.get("kind") == "section_heading":
        return False
    return _contains_latin(str(block.get("text", "") or ""))


def _contains_latin(value: str) -> bool:
    return any(("a" <= char.lower() <= "z") for char in value)


def _raw_map_item_score(item: dict) -> int:
    """Prefer provider items that contain the fields needed by the reader."""
    if not isinstance(item, dict):
        return 0
    score = sum(
        1 for key in ("translation", "one_liner")
        if isinstance(item.get(key), str) and item[key].strip()
    )
    score += int(isinstance(item.get("keywords"), list) and bool(item["keywords"]))
    score += int(isinstance(item.get("entities"), list) and bool(item["entities"]))
    return score


async def _run_map_batch(
    llm: LLMClient,
    batch_data: list[dict],
    paper_title_abstract: str,
    depth: int = 0,
    raw_log: list[dict] | None = None,
) -> list[dict]:
    """Request one Map batch and recover truncated/partial JSON responses."""
    if not batch_data:
        return []

    batch_block_ids = [item.get("block_id", "") for item in batch_data]

    def record(raw: str) -> None:
        if raw_log is not None:
            raw_log.append({"block_ids": list(batch_block_ids), "raw_response": raw})

    user_msg = f"""论文标题与摘要（仅用于理解上下文，不需要翻译）：
{paper_title_abstract}

待处理文本块（kind为figure/table/equation时text为其原始caption及紧邻说明文字）：
{json.dumps(batch_data, ensure_ascii=False)}"""
    parsed_by_id: dict[str, dict] = {}

    # Two attempts cover transient provider failures and JSON truncation.  A
    # concise reminder on the second attempt reduces the chance of another
    # verbose answer consuming the completion budget.
    for attempt in range(2):
        attempt_msg = user_msg
        if attempt:
            attempt_msg += "\n请严格输出一个完整JSON对象，results必须逐一覆盖每个block_id；不要省略任何块，也不要输出解释文字。"
        try:
            raw = await llm.chat(
                messages=[
                    {"role": "system", "content": MAP_SYSTEM_PROMPT},
                    {"role": "user", "content": attempt_msg},
                ],
                temperature=0.2 if attempt == 0 else 0,
                max_tokens=8192,
                response_format={"type": "json_object"},
            )
            record(raw)
            parsed = _extract_json_array(raw)
            current_by_id = {
                item.get("block_id"): item
                for item in parsed
                if isinstance(item, dict) and isinstance(item.get("block_id"), str)
            }
            # Merge retries per block.  A retry may be shorter than the first
            # response while still repairing one of the previously empty
            # items, so choosing solely by response length would lose it.
            for block_id, item in current_by_id.items():
                if _raw_map_item_score(item) >= _raw_map_item_score(parsed_by_id.get(block_id, {})):
                    parsed_by_id[block_id] = item
            normalized = [
                _normalize_map_result(block, parsed_by_id.get(block["block_id"]))
                for block in batch_data
            ]
            if not any(
                _map_result_needs_retry(block, result)
                for block, result in zip(batch_data, normalized, strict=True)
            ):
                return normalized
        except Exception:
            # Preserve any usable response from a previous attempt; if there
            # is none, the split fallback below will make a smaller request.
            continue

    normalized_by_id = {
        block["block_id"]: _normalize_map_result(block, parsed_by_id.get(block["block_id"]))
        for block in batch_data
    }
    missing_blocks = [
        block for block in batch_data
        if _map_result_needs_retry(block, normalized_by_id[block["block_id"]])
    ]

    # A provider often truncates only the tail of a large response.  Retry the
    # missing items in small chunks while keeping the valid items untouched.
    if missing_blocks and len(batch_data) > 1 and depth < 3:
        chunk_size = max(1, min(4, len(missing_blocks)))
        recovered: list[dict] = []
        for start in range(0, len(missing_blocks), chunk_size):
            recovered.extend(
                await _run_map_batch(
                    llm,
                    missing_blocks[start : start + chunk_size],
                    paper_title_abstract,
                    depth + 1,
                    raw_log=raw_log,
                )
            )
        for item in recovered:
            normalized_by_id[item["block_id"]] = item

    return [normalized_by_id[block["block_id"]] for block in batch_data]


# ── Figure Analysis Phase ─────────────────────────────────

FIGURE_SYSTEM_PROMPT = """你是一名科研图表解读助手。你会收到一张来自学术论文的图片（图/表截图）、其原始英文图注，以及图注前后紧邻的正文片段作为上下文。

请输出严格JSON：
{
  "figure_type": "line_chart | bar_chart | scatter | reaction_scheme | molecule_structure | workflow_diagram | microscopy_image | spectrum | table_data | other",
  "caption_zh": "图注的中文翻译",
  "core_takeaways": ["要点1（一句话，≤40字）", "要点2", "要点3（最多3条）"],
  "data_reading_notes": "若为图表/曲线/表格，用1-2句话说明坐标轴/关键列含义及应重点关注的趋势或对比；若为反应式或结构图，说明反应物→产物或结构要点",
  "entities": [{"name": "...", "category": "..."}]
}

只依据图片与提供文本作答，不得编造图中不存在的数据；若图像细节不足以确认精确数值，请如实说明。"""


async def run_figure_analysis(
    llm: LLMClient,
    caption_en: str,
    surrounding_text: str = "",
    image_base64: str = "",
) -> dict:
    """Analyze a single figure/table with optional multimodal input."""
    if image_base64:
        messages = [
            {"role": "system", "content": FIGURE_SYSTEM_PROMPT},
            {"role": "user", "content": [
                {"type": "text", "text": f"图注（原文）：{caption_en}\n上下文（原文，图注前后各1-2段）：{surrounding_text}"},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image_base64}"}},
            ]},
        ]
        raw = await llm.chat_vision(messages=messages)
    else:
        messages = [
            {"role": "system", "content": FIGURE_SYSTEM_PROMPT},
            {"role": "user", "content": f"图注（原文）：{caption_en}\n上下文（原文，图注前后各1-2段）：{surrounding_text}\n（无图片，请仅基于文本分析）"},
        ]
        raw = await llm.chat(messages=messages)

    return _parse_json(raw)


# ── Reduce Phase ──────────────────────────────────────────

REDUCE_SYSTEM_PROMPT = """你是一名论文精读教练。你将收到一篇论文按原文顺序排列的"一句话摘要"列表（而非全文原文）、论文标题与摘要、以及已去重的方法实体列表。请基于这些压缩后的线索，重建全文的逻辑链条与整体叙事，输出严格JSON：

{
  "narrative_summary": "200-350字的连贯中文总结，按'问题/动机→方法/思路→关键实验或推导→结果→结论与意义'的叙事顺序撰写，讲清楚'为什么这样做、怎么做、发现了什么'这条主线，不要逐段罗列",
  "contributions": ["贡献点1", "贡献点2"],
  "domain_tags": ["..."],
  "difficulty_estimate": "入门 | 中等 | 较难",
  "logic_chain": [
    {"block_id": "b0001", "section": "所属章节标题（若能判断）", "role_in_narrative": "该节点在整体逻辑中的角色，如'提出问题''方法设计''关键结果''局限性讨论'（必须使用简体中文）"}
  ]
}

logic_chain数组必须与输入的一句话列表一一对应、顺序一致，只新增role_in_narrative字段；每个节点的role_in_narrative必须非空且使用简体中文。"""


async def run_reduce_phase(
    llm: LLMClient,
    paper_title_abstract: str,
    ordered_one_liners: list[dict],
    deduped_entities: list[dict],
    raw_log: list[dict] | None = None,
) -> dict:
    """Run the Reduce phase to produce narrative summary and logic chain.

    Every raw provider response (initial + repair attempt) is appended to
    ``raw_log`` as ``{raw_response}`` when a list is supplied (T2.1 sidecar).
    """
    expected_block_ids = [
        item.get("block_id")
        for item in ordered_one_liners
        if isinstance(item, dict) and isinstance(item.get("block_id"), str)
    ]
    user_msg = f"""论文标题/摘要：{paper_title_abstract}
去重后的方法实体列表：{json.dumps(deduped_entities, ensure_ascii=False)}
按顺序排列的节点列表（block_id, kind, one_liner, section_guess）：{json.dumps(ordered_one_liners, ensure_ascii=False)}"""

    messages = [
        {"role": "system", "content": REDUCE_SYSTEM_PROMPT},
        {"role": "user", "content": user_msg},
    ]
    raw = await llm.chat(
        messages=messages,
        temperature=0.2,
        # A long logic chain plus reasoning can exhaust a 4K completion and
        # leave truncated JSON. MiMo supports a much larger output window.
        max_tokens=12288,
        response_format={"type": "json_object"},
    )
    if raw_log is not None:
        raw_log.append({"raw_response": raw})
    result = _normalize_reduce_result(_parse_json(raw))
    if _valid_reduce_result(result, expected_block_ids):
        return _complete_logic_chain(result, ordered_one_liners)

    # Give the provider one bounded repair attempt. Do not feed a potentially
    # huge/truncated response back; restate the schema constraint instead.
    result_chain = result.get("logic_chain", [])
    result_chain = result_chain if isinstance(result_chain, list) else []
    result_chain_ids = {
        item.get("block_id") for item in result_chain
        if isinstance(item, dict) and isinstance(item.get("block_id"), str)
    }
    missing_ids = [
        block_id for block_id in expected_block_ids
        if block_id not in result_chain_ids
    ]
    missing_hint = f"当前缺少这些block_id：{json.dumps(missing_ids[:30], ensure_ascii=False)}。" if missing_ids else ""
    repair_messages = [*messages, {
        "role": "user",
        "content": f"上一次输出不是完整的目标JSON。请重新输出单个JSON对象，必须包含非空 narrative_summary、contributions、domain_tags、difficulty_estimate 和 logic_chain；logic_chain必须按输入顺序覆盖每个block_id，role_in_narrative必须使用简体中文。{missing_hint}不要输出思考过程或Markdown围栏。",
    }]
    repaired_raw = await llm.chat(
        messages=repair_messages,
        temperature=0,
        max_tokens=12288,
        response_format={"type": "json_object"},
    )
    if raw_log is not None:
        raw_log.append({"raw_response": repaired_raw})
    repaired = _normalize_reduce_result(_parse_json(repaired_raw))
    if not _valid_reduce_result(repaired, expected_block_ids):
        # Keep a valid global summary if the provider still omitted a few
        # nodes.  The deterministic Chinese labels make every block navigable
        # and, importantly, prevent a successful-looking paper from exposing
        # an English/empty logic chain in the reader.
        repaired = _complete_logic_chain(repaired, ordered_one_liners)
    if not _valid_reduce_result(repaired, expected_block_ids):
        raise ValueError("MiMo 未返回完整的论文汇总 JSON，请重试或切换 mimo-v2.5")
    return repaired


# ── Chat System Prompt ────────────────────────────────────

def build_chat_system_prompt(
    title: str,
    title_zh: str,
    domain_tags: list[str],
    tldr: str,
    paper_context: str,
) -> str:
    return f"""你是本工作台内嵌的论文精读助手，用户正在阅读以下论文：

【论文元信息】
标题：{title} / {title_zh}
领域标签：{', '.join(domain_tags)}
一句话总结：{tldr}

{paper_context}

回答要求：
1. 默认使用简体中文回答；专业术语、模型名、数据集名等保留英文原词。
2. 回答必须基于以上论文内容；若问题的答案在论文中未被提及，必须明确说明"论文原文未提及/未讨论此问题"，禁止编造论文中不存在的内容或数据。
3. 引用论文具体内容时，在句末以"[b00xx]"标注来源block_id（仅标注确实来自该块的内容），便于用户点击溯源。
4. 数学公式使用$...$（行内）与$$...$$（块级），兼容Obsidian渲染，不使用\\( \\)或\\[ \\]。
5. 若问题明显超出本论文范围，可基于通用知识补充回答，但需明确区分"论文内容"与"补充知识"两部分。"""


# ── Note Synthesis ─────────────────────────────────────────

NOTE_SYNTHESIS_PROMPT = """你是一名帮助用户把"论文阅读过程中的问答与要点"整理成可长期保存的知识笔记的助手。

输入包括：
1. 论文元信息（标题、作者、年份、来源、领域标签）
2. 全文逻辑链与方法索引（结构化数据）
3. 用户在对话中选中、希望被纳入笔记的若干轮问答（按时间顺序，可能碎片化、跳跃式）

请输出一篇结构清晰、去重、语言连贯的Markdown笔记（而非把问答简单拼接），要求：
- 使用YAML frontmatter记录元信息
- 按"核心结论先行、细节展开在后"的原则组织内容，可自行归纳合适的二级标题
- 用户在问答中记录的"个人思考/疑问/后续TODO"，单独保留在末尾"个人笔记"区块
- 已知的方法实体名称与论文标题用[[双方括号]]包裹作为Obsidian双链
- 数学公式使用$ $ / $$ $$，代码使用带语言标注的代码块
- 不得虚构问答与结构化数据中都未出现的内容"""


async def synthesize_note(
    llm: LLMClient,
    paper_meta: dict,
    structured_context: dict,
    selected_messages: list[dict],
) -> str:
    """Generate a synthesized note from selected chat messages."""
    user_msg = f"""论文元信息：{json.dumps(paper_meta, ensure_ascii=False)}

结构化数据（逻辑链与方法索引）：{json.dumps(structured_context, ensure_ascii=False)}

用户选中的对话记录：
{json.dumps(selected_messages, ensure_ascii=False)}"""

    raw = await llm.chat(
        messages=[
            {"role": "system", "content": NOTE_SYNTHESIS_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        temperature=0.3,
        max_tokens=8192,
    )
    return raw


# ── Helpers ───────────────────────────────────────────────

def _extract_json_array(text: str) -> list[dict]:
    """Extract a JSON array from LLM output that may contain markdown fences."""
    # Try direct parse first
    try:
        parsed = json.loads(text)
        if isinstance(parsed, list):
            return [item for item in parsed if isinstance(item, dict)]
        if isinstance(parsed, dict):
            if isinstance(parsed.get("block_id"), str):
                return [parsed]
            # Prefer known wrapper fields; do not mistake keywords/entities for
            # the top-level result array when a provider returns one block.
            for key in ("results", "result", "blocks", "items", "data", "output"):
                value = parsed.get(key)
                if isinstance(value, list):
                    return [item for item in value if isinstance(item, dict)]
                if isinstance(value, dict) and isinstance(value.get("block_id"), str):
                    return [value]
    except json.JSONDecodeError:
        pass

    # Try extracting from code fence
    match = re.search(r"```(?:json)?\s*(\[[\s\S]*?\])\s*```", text)
    if match:
        try:
            parsed = json.loads(match.group(1))
            return [item for item in parsed if isinstance(item, dict)] if isinstance(parsed, list) else []
        except json.JSONDecodeError:
            pass

    # Try finding array in text
    match = re.search(r"\[[\s\S]*\]", text)
    if match:
        try:
            parsed = json.loads(match.group())
            return [item for item in parsed if isinstance(item, dict)] if isinstance(parsed, list) else []
        except json.JSONDecodeError:
            pass

    return []


def _parse_json(text: str) -> dict:
    """Parse JSON from LLM output."""
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        match = re.search(r"```(?:json)?\s*([\s\S]*?)\s*```", text)
        if match:
            try:
                parsed = json.loads(match.group(1))
                return parsed if isinstance(parsed, dict) else {}
            except json.JSONDecodeError:
                pass
        match = re.search(r"\{[\s\S]*\}", text)
        if match:
            try:
                parsed = json.loads(match.group())
                return parsed if isinstance(parsed, dict) else {}
            except json.JSONDecodeError:
                pass
    return {}


def _normalize_reduce_result(value: dict) -> dict:
    """Unwrap common provider envelopes around the Reduce payload."""
    current = value
    for _ in range(3):
        if not isinstance(current, dict):
            return {}
        if "narrative_summary" in current or "logic_chain" in current:
            return current
        nested = next(
            (current.get(key) for key in ("result", "results", "data", "output", "response")
             if isinstance(current.get(key), dict)),
            None,
        )
        if nested is None:
            return current
        current = nested
    return current if isinstance(current, dict) else {}


def _valid_reduce_result(value: dict, expected_block_ids: list[str] | None = None) -> bool:
    """Validate Reduce output, including a complete Chinese logic chain."""
    if not (
        isinstance(value, dict)
        and isinstance(value.get("narrative_summary"), str)
        and bool(value["narrative_summary"].strip())
        and isinstance(value.get("logic_chain"), list)
        and bool(value["logic_chain"])
    ):
        return False

    chain = value["logic_chain"]
    chain_ids = set()
    for item in chain:
        if not isinstance(item, dict) or not isinstance(item.get("block_id"), str):
            return False
        role = item.get("role_in_narrative")
        if not isinstance(role, str) or not role.strip() or not _contains_chinese(role):
            return False
        chain_ids.add(item["block_id"])
    if expected_block_ids and not set(expected_block_ids).issubset(chain_ids):
        return False
    return True


def _contains_chinese(value: str) -> bool:
    return any("\u4e00" <= char <= "\u9fff" for char in value)


def _complete_logic_chain(value: dict, ordered_one_liners: list[dict]) -> dict:
    """Fill omitted/English Reduce nodes with stable, Chinese fallback roles."""
    if not isinstance(value, dict):
        return {}
    chain_items = value.get("logic_chain", [])
    chain_items = chain_items if isinstance(chain_items, list) else []
    existing = {
        item.get("block_id"): item
        for item in chain_items
        if isinstance(item, dict) and isinstance(item.get("block_id"), str)
    }
    total = max(1, len(ordered_one_liners))
    chain = []
    for index, source in enumerate(ordered_one_liners):
        if not isinstance(source, dict) or not isinstance(source.get("block_id"), str):
            continue
        block_id = source["block_id"]
        item = existing.get(block_id, {})
        role = item.get("role_in_narrative") if isinstance(item, dict) else ""
        role = role.strip() if isinstance(role, str) else ""
        if not role or not _contains_chinese(role):
            role = _fallback_role(source.get("kind", ""), index, total)
        section = item.get("section") if isinstance(item, dict) else ""
        if not isinstance(section, str) or not section.strip():
            section = str(source.get("section_guess", "") or "")
        chain.append({
            "block_id": block_id,
            "section": section,
            "role_in_narrative": role,
        })
    value["logic_chain"] = chain
    return value


def _fallback_role(kind: str, index: int, total: int) -> str:
    if kind == "section_heading":
        return "章节标题"
    if index == 0:
        return "论文主题"
    ratio = index / total
    if ratio < 0.2:
        return "研究背景"
    if ratio < 0.52:
        return "方法设计"
    if ratio < 0.82:
        return "实验与结果"
    if ratio < 0.94:
        return "分析与讨论"
    return "结论与补充"
