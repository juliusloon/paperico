"""Raw sidecar (T2.1) and layered chat context (T2.2) tests."""

import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from app.core.config import settings
from app.core.models import _now
from app.core.storage import analyses_dir, write_analysis_raw
from app.services import analysis
from app.services.context import (
    LOGIC_CHAIN_BUDGET,
    METHOD_INDEX_TOP_K,
    build_paper_context,
    clip_text,
    compact_logic_chain,
    compact_method_index,
)


class MapLLM:
    """Returns one valid Map result per requested block."""

    async def chat(self, messages, **_kwargs):
        user_msg = messages[-1]["content"]
        payload_start = user_msg.index("[")
        batch = json.loads(user_msg[payload_start:user_msg.rindex("]") + 1])
        return json.dumps({"results": [
            {
                "block_id": item["block_id"],
                "translation": f"第{item['block_id']}段译文",
                "one_liner": f"{item['block_id']}一句话概括",
                "keywords": ["测试"],
                "entities": [],
            }
            for item in batch
        ]}, ensure_ascii=False)


class ReduceLLM:
    async def chat(self, **_kwargs):
        return json.dumps({
            "narrative_summary": "全文叙事",
            "contributions": ["贡献一"],
            "domain_tags": ["测试"],
            "difficulty_estimate": "中等",
            "logic_chain": [],
        }, ensure_ascii=False)


class RawSidecarTests(unittest.TestCase):
    def test_map_phase_raw_log_captures_batch_responses(self):
        raw_log: list[dict] = []
        blocks = [
            {"id": f"bp{i:04d}", "kind": "paragraph", "text_original": f"Paragraph {i}"}
            for i in range(30)
        ]
        results = asyncio.run(analysis.run_map_phase(
            MapLLM(), blocks, "标题：T\n摘要：A", strict=True, raw_log=raw_log,
        ))
        self.assertEqual(len(results), 30)
        # 30 blocks / batch 12 → 3 batches, each response recorded once.
        self.assertEqual(len(raw_log), 3)
        recorded_ids = [block_id for entry in raw_log for block_id in entry["block_ids"]]
        self.assertEqual(sorted(recorded_ids), sorted(block["id"] for block in blocks))
        for entry in raw_log:
            self.assertIn("raw_response", entry)
            # The raw response must be replayable JSON on its own.
            parsed = json.loads(entry["raw_response"])
            self.assertTrue(parsed["results"])

    def test_reduce_phase_raw_log_captures_attempts(self):
        raw_log: list[dict] = []
        one_liners = [{"block_id": "bp0000", "kind": "paragraph", "one_liner": "概括"}]
        result = asyncio.run(analysis.run_reduce_phase(
            ReduceLLM(), "标题：T", one_liners, [], raw_log=raw_log,
        ))
        self.assertEqual(result["narrative_summary"], "全文叙事")
        self.assertGreaterEqual(len(raw_log), 1)
        self.assertIn("raw_response", raw_log[0])
        json.loads(raw_log[0]["raw_response"])

    def test_sidecar_file_structure_on_disk(self):
        original_root = settings.storage_root
        try:
            with tempfile.TemporaryDirectory() as tmp:
                settings.storage_root = Path(tmp)
                map_raw = [{"block_ids": ["bp0000"], "raw_response": "{}"}]
                self.assertTrue(write_analysis_raw("paperabc01", "map_raw.json", {
                    "model": "test-model", "created_at": _now(), "batches": map_raw,
                }))
                target = analyses_dir("paperabc01") / "map_raw.json"
                self.assertEqual(
                    target, Path(tmp) / "analyses" / "paperabc01" / "map_raw.json",
                )
                data = json.loads(target.read_text(encoding="utf-8"))
                self.assertEqual(data["model"], "test-model")
                self.assertEqual(data["batches"], map_raw)
                self.assertTrue(data["created_at"])
        finally:
            settings.storage_root = original_root

    def test_sidecar_write_failure_never_blocks_pipeline(self):
        original_root = settings.storage_root
        try:
            with tempfile.TemporaryDirectory() as tmp:
                settings.storage_root = Path(tmp)
                # A file where the sidecar directory should be forces OSError.
                blocker = Path(tmp) / "analyses" / "paperabc01"
                blocker.mkdir(parents=True)
                (blocker / "reduce_raw.json").write_text("not-a-dir-parent", encoding="utf-8")
                (blocker / "reduce_raw.json").chmod(0o444)
                blocker.chmod(0o555)
                try:
                    self.assertFalse(write_analysis_raw("paperabc01", "reduce_raw.json", {}))
                finally:
                    blocker.chmod(0o755)
        finally:
            settings.storage_root = original_root


class LayeredContextTests(unittest.TestCase):
    @staticmethod
    def _long_paper(block_count: int = 200):
        blocks = []
        for i in range(block_count):
            if i % 10 == 0:
                blocks.append({
                    "id": f"b{i:04d}", "kind": "section_heading",
                    "text_original": f"Section {i}", "section_title": "",
                    "one_liner": "", "role_in_narrative": "",
                })
            else:
                blocks.append({
                    "id": f"b{i:04d}", "kind": "paragraph",
                    "text_original": f"Paragraph {i}", "section_title": "",
                    "one_liner": f"节点{i}的一句话概括，长度适中但不短。" * 2,
                    "role_in_narrative": ["提出问题", "方法", "结果"][i % 3],
                })
        return blocks

    def test_long_paper_stays_within_budget_and_keeps_headings_whole(self):
        blocks = self._long_paper()
        output = compact_logic_chain(blocks, budget=2000)

        self.assertLessEqual(len(output), 2000)
        # ① Every section heading survives regardless of position.
        for block in blocks:
            if block["kind"] == "section_heading":
                self.assertIn(f"§ [{block['id']}] {block['text_original']}", output)
        # ③ No line is cut in half: each output line must exactly match one
        # of the lines that could have been generated from the input.
        expected_lines = set()
        for block in blocks:
            if block["kind"] == "section_heading":
                expected_lines.add(f"§ [{block['id']}] {block['text_original']}")
            else:
                expected_lines.add(
                    f"{block['role_in_narrative']} · [{block['id']}] {block['one_liner']}"
                )
        for line in output.split("\n"):
            self.assertIn(line, expected_lines)

    def test_method_index_ranks_by_mentions_and_caps_top_k(self):
        entities = [
            {"name": f"Entity{i}", "category": "METHOD", "block_refs": [f"b{j:04d}" for j in range(i + 1)]}
            for i in range(60)
        ]
        output = compact_method_index(entities)
        lines = output.split("\n")
        self.assertEqual(len(lines), METHOD_INDEX_TOP_K)
        # Stable sort: the highest-mention entity leads; rank 40 is Entity20.
        self.assertTrue(lines[0].startswith("Entity59(METHOD)"))
        self.assertTrue(lines[-1].startswith("Entity20(METHOD)"))
        self.assertIn("…(+48)", lines[0])
        self.assertNotIn("Entity19(", output)  # rank 41+ entities are dropped

    def test_build_paper_context_contains_both_sections(self):
        blocks = self._long_paper(20)
        entities = [{"name": "MethodA", "category": "METHOD", "block_refs": ["b0001"]}]
        context = build_paper_context(blocks, entities)
        self.assertIn("【全文逻辑链（压缩版，按原文顺序）】", context)
        self.assertIn("【已识别方法/实体索引】", context)
        self.assertIn("MethodA(METHOD) → [b0001]", context)

    def test_clip_text_marks_explicit_cut(self):
        self.assertEqual(clip_text("short", 10), "short")
        clipped = clip_text("x" * 50, 10)
        self.assertEqual(clipped, "x" * 10 + "…")
        self.assertEqual(clip_text(None, 10), "")
        self.assertEqual(clip_text(123, 10), "123")

    def test_budget_guard_matches_constant(self):
        # The published budget constant stays the single source of truth.
        self.assertEqual(LOGIC_CHAIN_BUDGET, 6000)


if __name__ == "__main__":
    unittest.main()
