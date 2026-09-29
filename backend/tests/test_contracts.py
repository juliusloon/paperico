"""Contract tests for agentero-execution-plan T0: status/error codes (T0.1),
fixed-width timestamps (T0.2), and resolve_llm convergence (T0.3)."""

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app.core import crypto
from app.core.models import _now
from app.core.schemas import PaperListItem, PaperStatusOut
from app.core.status import ErrorCode, PipelineError, error_code_of, set_paper_error
from app.services.llm import LLMClient, LLMServiceError
from app.services.mineru import MinerUParseFailed, MinerUSubmitFailed, MinerUTimeout
from app.services.profiles import LlmRole, resolve_llm
from scripts.migrate_schema_v2 import canonical_timestamp, migrate

FIXED_SAMPLE = "2026-09-29T08:30:00.123Z"


def make_settings(*profiles, **assignment):
    return {
        "model_profiles": list(profiles),
        "profile_assignment": assignment,
    }


def profile(pid, base_url="", api_key="", model=""):
    stored_key = crypto.encrypt(api_key) if api_key else ""
    return {"id": pid, "base_url": base_url, "api_key": stored_key, "model": model}


class FixedWidthTimestampTests(unittest.TestCase):
    def test_now_is_rfc3339_milliseconds(self):
        value = _now()
        self.assertEqual(len(value), 24)
        self.assertTrue(value.endswith("Z"))
        self.assertRegex(value, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

    def test_canonical_timestamp_is_idempotent(self):
        # None means "already canonical, nothing to rewrite".
        self.assertIsNone(canonical_timestamp(FIXED_SAMPLE))

    def test_canonical_timestamp_rewrites_legacy_forms(self):
        for legacy, expected in (
            ("2026-09-29T08:30:00.123456+00:00", FIXED_SAMPLE),
            ("2026-09-29T08:30:00+00:00", "2026-09-29T08:30:00.000Z"),
            ("2026-09-29T08:30:00", "2026-09-29T08:30:00.000Z"),
        ):
            self.assertEqual(canonical_timestamp(legacy), expected, legacy)

    def test_migration_adds_column_and_rewrites_timestamps(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "paperico.db"
            conn = sqlite3.connect(str(db_path))
            conn.execute("CREATE TABLE papers (id TEXT PRIMARY KEY, error_message TEXT, created_at TEXT, last_opened_at TEXT)")
            conn.execute(
                "INSERT INTO papers (id, error_message, created_at, last_opened_at) VALUES (?,?,?,?)",
                ("p1", "", "2026-09-29T08:30:00.123456+00:00", "2026-09-29T08:30:00+00:00"),
            )
            conn.execute(
                "INSERT INTO papers (id, error_message, created_at, last_opened_at) VALUES (?,?,?,?)",
                ("p2", "", FIXED_SAMPLE, None),
            )
            conn.commit()

            result = migrate(db_path)
            self.assertTrue(result["error_code_column_added"])
            self.assertEqual(result["timestamps"]["papers.created_at"], 1)
            self.assertEqual(result["timestamps"]["papers.last_opened_at"], 1)

            rows = conn.execute("SELECT id, created_at, last_opened_at FROM papers ORDER BY id").fetchall()
            self.assertEqual(rows[0], ("p1", FIXED_SAMPLE, "2026-09-29T08:30:00.000Z"))
            self.assertEqual(rows[1], ("p2", FIXED_SAMPLE, None))

            # Re-running must be a no-op.
            second = migrate(db_path)
            self.assertFalse(second["error_code_column_added"])
            self.assertEqual(second["timestamps"], {})
            conn.close()


class ProfileResolutionTests(unittest.TestCase):
    def test_explicit_assignment_wins_even_if_unconfigured(self):
        settings = make_settings(
            profile("primary", base_url="https://x/v1", api_key="k", model="m"),
            chat="primary",
        )
        client = resolve_llm(settings, LlmRole.CHAT)
        self.assertEqual(client.model, "m")

    def test_logic_chain_falls_back_to_translation_profile(self):
        settings = make_settings(
            profile("main", base_url="https://x/v1", api_key="k", model="m"),
            translation_and_extraction="main",
        )
        client = resolve_llm(settings, LlmRole.LOGIC_CHAIN_AND_SUMMARY)
        self.assertEqual(client.model, "m")

    def test_chat_chain_falls_back_to_translation(self):
        settings = make_settings(
            profile("main", base_url="https://x/v1", api_key="k", model="m"),
            translation_and_extraction="main",
        )
        self.assertEqual(resolve_llm(settings, LlmRole.CHAT).model, "m")

    def test_note_chain_falls_back_to_chat(self):
        settings = make_settings(
            profile("main", base_url="https://x/v1", api_key="k", model="m"),
            chat="main",
        )
        self.assertEqual(resolve_llm(settings, LlmRole.NOTE_SYNTHESIS).model, "m")

    def test_configured_profile_preferred_over_blank_assignment(self):
        settings = make_settings(
            profile("stale"),  # unconfigured, assigned but empty credentials
            profile("good", base_url="https://x/v1", api_key="k", model="m"),
        )
        client = resolve_llm(settings, LlmRole.TRANSLATION_AND_EXTRACTION)
        self.assertEqual(client.model, "m")

    def test_single_profile_used_even_if_unconfigured(self):
        settings = make_settings(profile("only"))
        client = resolve_llm(settings, LlmRole.CHAT)
        reference = LLMClient()
        self.assertEqual(
            (client.base_url, client.api_key, client.model),
            (reference.base_url, reference.api_key, reference.model),
        )

    def test_falls_back_to_environment_default(self):
        client = resolve_llm(make_settings(), LlmRole.CHAT)
        self.assertEqual(client.base_url, LLMClient().base_url)


class ErrorCodeTests(unittest.TestCase):
    def test_typed_pipeline_error_carries_code(self):
        exc = PipelineError("未配置", ErrorCode.LLM_NOT_CONFIGURED)
        self.assertEqual(error_code_of(exc), ErrorCode.LLM_NOT_CONFIGURED)

    def test_mineru_service_errors_map_to_codes(self):
        self.assertEqual(error_code_of(MinerUSubmitFailed("boom")), ErrorCode.MINERU_SUBMIT_FAILED)
        self.assertEqual(error_code_of(MinerUParseFailed("boom")), ErrorCode.MINERU_PARSE_FAILED)
        self.assertEqual(error_code_of(MinerUTimeout("boom")), ErrorCode.MINERU_TIMEOUT)

    def test_type_based_classification(self):
        self.assertEqual(error_code_of(LLMServiceError("boom")), ErrorCode.LLM_CALL_FAILED)
        self.assertEqual(error_code_of(json.JSONDecodeError("bad", "doc", 0)), ErrorCode.JSON_PARSE_FAILED)
        self.assertEqual(error_code_of(RuntimeError("mystery")), ErrorCode.INTERNAL)

    def test_set_paper_error_writes_all_fields(self):
        class Paper:
            status = ""
            error_message = ""
            error_code = None

        paper = Paper()
        set_paper_error(paper, PipelineError("未找到原始 PDF", ErrorCode.PDF_MISSING))
        self.assertEqual(paper.status, "error")
        self.assertEqual(paper.error_code, "PDF_MISSING")
        self.assertIn("PDF", paper.error_message)

        long = RuntimeError("x" * 900)
        set_paper_error(paper, long)
        self.assertEqual(len(paper.error_message), 500)
        self.assertEqual(paper.error_code, "INTERNAL")


class SchemaContractTests(unittest.TestCase):
    def test_paper_status_out_carries_error_code(self):
        out = PaperStatusOut(id="p1", status="error", error_message="boom", error_code="MINERU_TIMEOUT")
        payload = json.loads(out.model_dump_json())
        self.assertEqual(payload["error_code"], "MINERU_TIMEOUT")

    def test_paper_list_item_defaults_error_code(self):
        out = PaperListItem(
            id="p1", title="", title_zh="", authors=[], year=None, domain_tags=[],
            status="ready", project_id=None, source_type="pdf_upload",
            original_file_name="a.pdf", created_at=FIXED_SAMPLE, last_opened_at=None,
        )
        self.assertEqual(out.error_code, "")


if __name__ == "__main__":
    unittest.main()
