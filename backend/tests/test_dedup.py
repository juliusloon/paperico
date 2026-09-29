"""Upload dedup by sha256 (T1.4) and the matching migration column."""

import hashlib
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import BackgroundTasks, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.api.papers import create_paper
from app.core.config import settings
from app.core.database import Base
from app.core.models import Paper
from app.core.schemas import PaperListItem
from scripts.migrate_schema_v2 import migrate


class FakeUpload:
    def __init__(self, data: bytes, filename: str = "a.pdf"):
        self.filename = filename
        self._data = data
        self._pos = 0

    async def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            chunk, self._pos = self._data[self._pos:], len(self._data)
            return chunk
        chunk = self._data[self._pos:self._pos + size]
        self._pos += len(chunk)
        return chunk


def fake_request():
    return SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace()))


class DedupTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        self.addCleanup(self.engine.dispose)

    async def asyncSetUp(self):
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.session_factory = async_sessionmaker(self.engine, expire_on_commit=False)

    async def upload(self, db, data: bytes, filename: str = "a.pdf") -> PaperListItem:
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(settings, "storage_root", Path(tmp)):
                item = await create_paper(
                    fake_request(), BackgroundTasks(), FakeUpload(data, filename), None, None, db
                )
        return item

    async def test_same_file_second_upload_is_rejected_with_409(self):
        payload = b"%PDF-1.4 identical content"
        async with self.session_factory() as db:
            first = await self.upload(db, payload, "first.pdf")
            stored = await db.get(Paper, first.id)
            self.assertEqual(stored.file_sha256, hashlib.sha256(payload).hexdigest())

            with self.assertRaises(HTTPException) as caught:
                await self.upload(db, payload, "second.pdf")
            self.assertEqual(caught.exception.status_code, 409)
            self.assertIn(first.id, caught.exception.detail)
            self.assertIn("重复", caught.exception.detail)

            # the rejected copy must not leave a stray pdf or row behind
            third = await self.upload(db, b"%PDF-1.4 different content", "third.pdf")
            self.assertNotEqual(third.id, first.id)
            rows = (await db.execute(select(Paper))).scalars().all()
            self.assertEqual({p.id for p in rows}, {first.id, third.id})

    async def test_not_pdf_is_still_rejected_before_hashing(self):
        async with self.session_factory() as db:
            with self.assertRaises(HTTPException) as caught:
                await self.upload(db, b"PK zip masquerading", "evil.pdf")
            self.assertEqual(caught.exception.status_code, 400)

    async def test_url_paper_has_no_hash(self):
        async with self.session_factory() as db:
            with tempfile.TemporaryDirectory() as tmp:
                with patch.object(settings, "storage_root", Path(tmp)):
                    item = await create_paper(
                        fake_request(), BackgroundTasks(), None, None,
                        "https://arxiv.org/pdf/2601.12345", db,
                    )
            stored = await db.get(Paper, item.id)
            self.assertIsNone(stored.file_sha256)
            self.assertEqual(stored.source_type, "url_pdf")


class Sha256MigrationTests(unittest.TestCase):
    def test_migration_adds_file_sha256_column_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "paperico.db"
            conn = sqlite3.connect(str(db_path))
            conn.execute("CREATE TABLE papers (id TEXT PRIMARY KEY, title TEXT, created_at TEXT)")
            conn.commit()

            result = migrate(db_path)
            self.assertTrue(result["file_sha256_column_added"])
            columns = {row[1] for row in conn.execute("PRAGMA table_info(papers)")}
            self.assertIn("file_sha256", columns)

            self.assertFalse(migrate(db_path)["file_sha256_column_added"])
            conn.close()


if __name__ == "__main__":
    unittest.main()
