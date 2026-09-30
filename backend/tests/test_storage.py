"""Migration regressions: preserve identity and HTTP range support."""

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import BackgroundTasks, FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.api.papers import reparse_paper, router
from app.core.config import BACKEND_ROOT, Settings, settings
from app.core.database import Base, get_db
from app.core.models import Paper
from app.core.storage import migrate_storage_references, resolve_paper_pdf, resolve_storage_path


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # resolve() so expectations match on macOS, where /tmp and /var are
        # symlinks into /private (resolve_storage_path always resolves).
        self.root = (Path(self.tmp.name) / "moved-repo" / "storage").resolve()
        (self.root / "pdfs").mkdir(parents=True)
        self.patch = patch.object(settings, "storage_root", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_rebases_mac_windows_and_relative_paths(self):
        expected = self.root / "pdfs" / "abc.pdf"
        for value in ["/Users/old/app/storage/pdfs/abc.pdf", r"C:\old\storage\pdfs\abc.pdf", "pdfs/abc.pdf", str(expected)]:
            with self.subTest(value=value):
                self.assertEqual(resolve_storage_path(value, "pdfs"), expected)

    def test_no_cross_paper_fallback_to_shared_legacy_file(self):
        legacy = self.root / "pdfs" / "None.pdf"
        legacy.write_bytes(b"%PDF-1.4 legacy")
        self.assertEqual(resolve_paper_pdf("/old/storage/pdfs/None.pdf", "original"), legacy)
        self.assertIsNone(resolve_paper_pdf("/old/storage/pdfs/missing.pdf", "missing"))
        self.assertIsNone(resolve_paper_pdf("", "another"))

    def test_missing_recorded_path_can_use_only_own_id(self):
        own = self.root / "pdfs" / "abc.pdf"
        own.write_bytes(b"%PDF-1.4 abc")
        self.assertEqual(resolve_paper_pdf("", "abc"), own)
        self.assertIsNone(resolve_paper_pdf("", "xyz"))

    def test_traversal_and_symlinks_cannot_escape_storage(self):
        outside = Path(self.tmp.name) / "outside.pdf"
        outside.write_bytes(b"%PDF-1.4 private")
        (self.root / "pdfs" / "escape.pdf").symlink_to(outside)
        for value in ["pdfs/../../outside.pdf", str(outside), "pdfs/escape.pdf"]:
            with self.subTest(value=value):
                self.assertIsNone(resolve_storage_path(value, "pdfs"))

    def test_original_pdf_endpoint_identity_range_and_404(self):
        (self.root / "pdfs" / "None.pdf").write_bytes(b"%PDF-1.4\nlegacy-source")
        (self.root / "pdfs" / "second.pdf").write_bytes(b"%PDF-1.4\nsecond-source")
        records = {
            "first": SimpleNamespace(id="first", pdf_path="/old/storage/pdfs/None.pdf", original_file_name="原文.pdf"),
            "second": SimpleNamespace(id="second", pdf_path="pdfs/second.pdf", original_file_name="second.pdf"),
            "missing": SimpleNamespace(id="missing", pdf_path="pdfs/missing.pdf", original_file_name="missing.pdf", source_type="pdf_upload"),
        }

        class FakeDB:
            async def get(self, model, key):
                return records.get(key)

        app = FastAPI()
        app.include_router(router, prefix="/api/papers")
        app.dependency_overrides[get_db] = lambda: FakeDB()
        with TestClient(app) as client:
            for key, expected in [("first", b"legacy-source"), ("second", b"second-source")]:
                response = client.get(f"/api/papers/{key}/pdf")
                self.assertEqual(response.status_code, 200)
                self.assertTrue(response.content.endswith(expected))
                self.assertEqual(response.headers["content-type"], "application/pdf")
                self.assertTrue(response.headers["content-disposition"].startswith("inline;"))
            response = client.get("/api/papers/first/pdf", headers={"Range": "bytes=0-4"})
            self.assertEqual(response.status_code, 206)
            self.assertEqual(response.content, b"%PDF-")
            self.assertEqual(client.get("/api/papers/missing/pdf").status_code, 404)
            self.assertEqual(client.get("/api/papers/unknown/pdf").status_code, 404)
            # Must reject before touching existing analysis or launching tasks.
            self.assertEqual(client.post("/api/papers/missing/reparse").status_code, 404)

    def test_default_database_is_independent_of_launch_directory(self):
        config = Settings(_env_file=None)
        self.assertEqual(config.database_url, f"sqlite+aiosqlite:///{BACKEND_ROOT / 'paperico.db'}")


class MigrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_migration_is_idempotent_and_survives_another_move(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "first"
            (root / "pdfs").mkdir(parents=True)
            (root / "pdfs" / "None.pdf").write_bytes(b"%PDF-1.4 source")
            (root / "mineru_output" / "first").mkdir(parents=True)
            engine = create_async_engine("sqlite+aiosqlite:///:memory:")
            try:
                async with engine.begin() as connection:
                    await connection.run_sync(Base.metadata.create_all)
                async with async_sessionmaker(engine, expire_on_commit=False)() as db:
                    db.add(Paper(id="first", pdf_path="/old/storage/pdfs/None.pdf", mineru_output_dir="/old/storage/mineru_output/first"))
                    db.add(Paper(id="missing", pdf_path="/old/storage/pdfs/missing.pdf"))
                    await db.commit()
                    with patch.object(settings, "storage_root", root):
                        report = await migrate_storage_references(db)
                        self.assertEqual(report, {"papers": 2, "updated": 1, "missing_pdfs": 1})
                        self.assertEqual((await migrate_storage_references(db))["updated"], 0)
                    value = (await db.execute(select(Paper.pdf_path).where(Paper.id == "first"))).scalar_one()
                    self.assertEqual(value, "pdfs/None.pdf")
                    moved = Path(tmp) / "second"
                    root.rename(moved)
                    with patch.object(settings, "storage_root", moved):
                        self.assertEqual(resolve_paper_pdf(value, "first"), moved.resolve() / "pdfs" / "None.pdf")
                        self.assertEqual((await migrate_storage_references(db))["updated"], 0)
                        cached = moved / "mineru_output" / "first" / "content_list.json"
                        cached.write_text("[]")
                        # Reparse must find a migrated cache, without launching
                        # a paid external parse during this regression test.
                        tasks = BackgroundTasks()
                        request = SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace()))
                        response = await reparse_paper("first", request, tasks, db)
                        self.assertEqual(response.status, "parsed")
                        self.assertEqual(len(tasks.tasks), 1)
            finally:
                await engine.dispose()
