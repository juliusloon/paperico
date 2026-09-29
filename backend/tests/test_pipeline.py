import asyncio
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from app.core import crypto
from app.core.config import settings
from app.services import analysis, mineru, mineru_chem
from app.services.llm import LLMClient, LLMServiceError


class FakeResponse:
    def __init__(self, payload=None, content=b"", status_code=200):
        self._payload = payload or {}
        self.content = content
        self.status_code = status_code
        self.headers = {"content-type": "application/json"}

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeMinerUClient:
    def __init__(self, zip_bytes, task_ids=None):
        self.zip_bytes = zip_bytes
        self.task_ids = task_ids
        self.post_calls = []
        self.put_calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def post(self, url, **kwargs):
        self.post_calls.append((url, kwargs))
        data = {
            "batch_id": "batch-1",
            "file_urls": ["https://upload.test/file"],
        }
        if self.task_ids is not None:
            data["task_ids"] = self.task_ids
        return FakeResponse({"code": 0, "data": data})

    async def put(self, url, **kwargs):
        self.put_calls.append((url, kwargs))
        return FakeResponse()

    async def get(self, url, **_kwargs):
        if "extract-results/batch" in url:
            return FakeResponse({"code": 0, "data": {"extract_result": [{"state": "done", "full_zip_url": "https://download.test/result.zip"}]}})
        if url == "https://download.test/result.zip":
            return FakeResponse(content=self.zip_bytes)
        raise AssertionError(f"Unexpected URL: {url}")


class FakeLLMResponse:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code
        self.text = json.dumps(payload)

    @property
    def is_success(self):
        return 200 <= self.status_code < 300

    def json(self):
        return self._payload


class FakeLLMClient:
    def __init__(self, response):
        self.response = response
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.response


class PipelineTests(unittest.TestCase):
    def test_encryption_key_survives_process_cache_reset(self):
        original_root = settings.storage_root
        original_key = settings.encryption_key
        original_fernet = crypto._fernet
        try:
            with tempfile.TemporaryDirectory() as tmp:
                settings.storage_root = Path(tmp)
                settings.encryption_key = ""
                crypto._fernet = None
                ciphertext = crypto.encrypt("secret-value")
                self.assertEqual(crypto.decrypt(ciphertext), "secret-value")
                crypto._fernet = None
                settings.encryption_key = ""
                self.assertEqual(crypto.decrypt(ciphertext), "secret-value")
                self.assertEqual((Path(tmp) / ".paperico.key").stat().st_mode & 0o777, 0o600)
        finally:
            settings.storage_root = original_root
            settings.encryption_key = original_key
            crypto._fernet = original_fernet

    def test_local_pdf_uses_v4_signed_batch_pipeline(self):
        zip_buffer = io.BytesIO()
        with zipfile.ZipFile(zip_buffer, "w") as archive:
            archive.writestr("paper/content_list.json", json.dumps([
                {"type": "title", "text": "Test paper", "text_level": 1, "page_idx": 0},
                {"type": "text", "text": "Evidence paragraph", "page_idx": 0},
            ]))

        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                pdf_path = Path(tmp) / "sample.pdf"
                pdf_path.write_bytes(b"%PDF-1.4 test")
                client = FakeMinerUClient(zip_buffer.getvalue())
                with patch.object(mineru.httpx, "AsyncClient", return_value=client):
                    blocks, content_path = await mineru.run_full_pipeline(
                        file_path=str(pdf_path), base_url="https://mineru.net/api/v4",
                        api_key="token", options={"model_backend": "vlm", "is_ocr": False},
                        output_dir=str(Path(tmp) / "output"), poll_interval=0,
                    )
                self.assertTrue(client.post_calls[0][0].endswith("/file-urls/batch"))
                payload = client.post_calls[0][1]["json"]
                self.assertEqual(payload["model_version"], "vlm")
                self.assertFalse(payload["files"][0]["is_ocr"])
                self.assertEqual(client.put_calls[0][0], "https://upload.test/file")
                self.assertTrue(content_path.endswith("content_list.json"))
                self.assertEqual([block["kind"] for block in blocks], ["section_heading", "paragraph"])
                self.assertEqual(blocks[1]["text_original"], "Evidence paragraph")

        asyncio.run(run())

    def test_mineru_finds_prefixed_content_list_and_normalizes_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "task_content_list_v2.json").write_text("[]", encoding="utf-8")
            source = root / "task_content_list.json"
            source.write_text(json.dumps([
                {"type": "header", "text": "Journal header", "page_idx": 0},
                {"type": "text", "text": "Paper title", "text_level": 1, "page_idx": 0},
                {"type": "image", "img_path": "images/icon.jpg", "image_caption": [], "page_idx": 0},
                {"type": "chart", "img_path": "images/figure.jpg", "chart_caption": ["Figure 1.", "Main result"], "page_idx": 1},
                {"type": "list", "sub_type": "ref_text", "list_items": ["Reference 1"], "page_idx": 2},
                {"type": "text", "text": "Evidence paragraph", "page_idx": 2},
            ]), encoding="utf-8")

            self.assertEqual(mineru.find_content_list(root), str(source))
            blocks = mineru.parse_content_list(str(source))
            self.assertEqual([block["kind"] for block in blocks], ["section_heading", "figure", "paragraph"])
            self.assertEqual(blocks[1]["caption_original"], "Figure 1. Main result")
            self.assertEqual([block["order"] for block in blocks], [0, 1, 2])

    def test_chem_request_cannot_silently_fall_back_to_normal_batch(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                pdf_path = Path(tmp) / "chemistry.pdf"
                pdf_path.write_bytes(b"%PDF-1.4 test")
                client = FakeMinerUClient(b"")
                with patch.object(mineru.httpx, "AsyncClient", return_value=client):
                    with self.assertRaises(mineru_chem.MinerUChemUnavailable):
                        await mineru.submit_task(
                            file_path=str(pdf_path),
                            base_url="https://mineru.net/api/v4",
                            api_key="token",
                            options={"is_chem": True},
                        )
                self.assertTrue(client.post_calls[0][1]["json"]["is_chem"])
                self.assertEqual(client.put_calls, [])

        asyncio.run(run())

    def test_chem_batch_keeps_the_separate_task_id(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                pdf_path = Path(tmp) / "chemistry.pdf"
                pdf_path.write_bytes(b"%PDF-1.4 test")
                client = FakeMinerUClient(b"", task_ids=["chem-task-1"])
                with patch.object(mineru.httpx, "AsyncClient", return_value=client):
                    result = await mineru.submit_task(
                        file_path=str(pdf_path),
                        base_url="https://mineru.net/api/v4",
                        api_key="token",
                        options={"is_chem": True},
                    )
                self.assertEqual(result["chem_task_id"], "chem-task-1")
                self.assertEqual(result["batch_id"], "batch-1")
                self.assertEqual(len(client.put_calls), 1)

        asyncio.run(run())

    def test_chem_bundle_schema_and_artifact_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            crop_path = "moldet_yolo/molecule_crops/figure/mol_0001.jpg"
            crop = root / crop_path
            crop.parent.mkdir(parents=True)
            crop.write_bytes(b"jpeg")
            payload = {
                "molecule_table": {
                    "columns": [
                        "mol_id",
                        "mol_smiles",
                        "mol_molfile",
                        "page_idx",
                        "page_bbox",
                    ],
                    "data": [{
                        "mol_id": "mol_0001",
                        "mol_smiles": "CCO",
                        "mol_molfile": "mol block",
                        "page_idx": 0,
                        "page_bbox": [1, 2, 3, 4],
                        "mol_img": crop_path,
                        "mol_graph": "molgraph/mol_0001.png",
                    }],
                },
                "reaction_table": {
                    "columns": [
                        "reaction_id",
                        "reaction_conditions",
                        "reactants",
                        "products",
                        "page_idx",
                    ],
                    "data": [{
                        "reaction_id": "reaction_0001",
                        "reaction_conditions": [],
                        "reactants": [],
                        "products": [],
                        "page_idx": 0,
                        "reaction_figure": "reaction_extraction/reaction_0001.jpg",
                        "reactants_smiles": [{
                            "reactant_1": {"crop_path": crop_path},
                        }],
                    }],
                },
                "summary": {"total_molecules": 1, "total_reactions": 1},
            }
            (root / "demonstration_tables.json").write_text(
                json.dumps(payload), encoding="utf-8"
            )

            audit = mineru_chem.inspect_chem_bundle(root)

            self.assertEqual(audit["molecule_count"], 1)
            self.assertEqual(audit["reaction_count"], 1)
            self.assertEqual(audit["referenced_artifact_count"], 3)
            self.assertEqual(
                audit["missing_artifacts"],
                [
                    "molgraph/mol_0001.png",
                    "reaction_extraction/reaction_0001.jpg",
                ],
            )

    def test_map_json_parser_never_treats_keywords_as_block_results(self):
        single = json.dumps({
            "block_id": "b0001", "translation": "译文", "one_liner": "摘要",
            "keywords": ["SuFEx"], "entities": [],
        })
        wrapped = json.dumps({"results": [json.loads(single)]})
        self.assertEqual(analysis._extract_json_array(single)[0]["block_id"], "b0001")
        self.assertEqual(analysis._extract_json_array(wrapped)[0]["block_id"], "b0001")
        self.assertEqual(analysis._extract_json_array('{"keywords":["not-a-block"]}'), [])

    def test_map_strict_allows_non_chinese_proper_name_headings(self):
        class HeadingLLM:
            async def chat(self, **_kwargs):
                return json.dumps({
                    "results": [{
                        "block_id": "b0001",
                        "translation": "4.1.2 Mid-Mapper",
                        "one_liner": "Mid-Mapper章节设置",
                        "keywords": [],
                        "entities": [],
                    }],
                })

        async def run():
            result = await analysis.run_map_phase(
                HeadingLLM(),
                [{"id": "b0001", "kind": "section_heading", "text_original": "4.1.2 Mid-Mapper"}],
                strict=True,
            )
            self.assertEqual(result[0]["translation"], "4.1.2 Mid-Mapper")
            self.assertEqual(result[0]["one_liner"], "Mid-Mapper章节设置")

        asyncio.run(run())

    def test_reduce_result_unwraps_provider_envelope_and_requires_content(self):
        payload = {
            "narrative_summary": "完整摘要",
            "contributions": ["贡献"],
            "domain_tags": ["SuFEx"],
            "difficulty_estimate": "中等",
            "logic_chain": [{"block_id": "b1", "role_in_narrative": "提出问题"}],
        }
        self.assertEqual(analysis._normalize_reduce_result({"result": payload}), payload)
        self.assertTrue(analysis._valid_reduce_result(payload))
        self.assertFalse(analysis._valid_reduce_result({"narrative_summary": "", "logic_chain": []}))

    def test_llm_normalizes_mimo_endpoint_and_trims_credentials(self):
        async def run():
            fake = FakeLLMClient(FakeLLMResponse({"choices": [{"message": {"content": "OK"}}]}))
            client = LLMClient(
                base_url=" https://token-plan-cn.xiaomimimo.com/v1/chat/completions/ ",
                api_key=" tp-secret\n", model=" mimo-v2.5-pro ",
            )
            with patch("app.services.llm.httpx.AsyncClient", return_value=fake):
                result = await client.chat([{"role": "user", "content": "test"}], max_tokens=10)
            self.assertEqual(result, "OK")
            self.assertEqual(fake.calls[0][0], "https://token-plan-cn.xiaomimimo.com/v1/chat/completions")
            self.assertEqual(fake.calls[0][1]["headers"]["Authorization"], "Bearer tp-secret")
            self.assertEqual(fake.calls[0][1]["json"]["model"], "mimo-v2.5-pro")

        asyncio.run(run())

    def test_llm_surfaces_provider_error_without_secret(self):
        async def run():
            fake = FakeLLMClient(FakeLLMResponse(
                {"error": {"message": "model not available for this plan"}}, status_code=403,
            ))
            client = LLMClient(
                base_url="https://token-plan-cn.xiaomimimo.com/v1",
                api_key="tp-never-show", model="mimo-v2.5-pro",
            )
            with patch("app.services.llm.httpx.AsyncClient", return_value=fake):
                with self.assertRaises(LLMServiceError) as caught:
                    await client.chat([{"role": "user", "content": "test"}])
            message = str(caught.exception)
            self.assertIn("HTTP 403", message)
            self.assertIn("model not available", message)
            self.assertNotIn("tp-never-show", message)

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
