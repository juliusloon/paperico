"""Startup reconcile regressions (agentero plan T1.2)."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.core.config import settings
from app.core.database import Base
from app.core.models import Block, MethodEntity, Paper, block_entity_table
from app.services.reconcile import readable_content_list, reconcile_interrupted_papers


class FakeJobs:
    def __init__(self):
        self.submitted = []
        self.active = set()

    def has_active(self, paper_id):
        return paper_id in self.active

    def submit(self, kind, paper_id, coro):
        self.submitted.append((kind, paper_id))
        coro.close()  # tests never run the pipeline; close to silence warnings


class ReconcileTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        self.addCleanup(self.engine.dispose)

    async def asyncSetUp(self):
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.session_factory = async_sessionmaker(self.engine, expire_on_commit=False)

    async def test_resume_with_readable_cache_and_clears_stale_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "mineru_output" / "p1"
            output.mkdir(parents=True)
            (output / "content_list.json").write_text(
                json.dumps([{"type": "text", "text": "ok", "page_idx": 0}]), encoding="utf-8"
            )
            async with self.session_factory() as db:
                db.add(Paper(id="p1", status="parsing", mineru_output_dir="mineru_output/p1"))
                db.add_all([
                    Block(id="b1", paper_id="p1", order=1),
                    MethodEntity(id="e1", paper_id="p1", canonical_key="k", name="k"),
                ])
                await db.flush()
                await db.execute(
                    block_entity_table.insert().values(block_id="b1", entity_id="e1")
                )
                await db.commit()
                jobs = FakeJobs()
                with patch.object(settings, "storage_root", Path(tmp)):
                    report = await reconcile_interrupted_papers(db, jobs)

            self.assertEqual(report["in_flight"], 1)
            self.assertEqual(report["resumed"], 1)
            self.assertEqual(jobs.submitted, [("map", "p1")])
            paper = (await db.execute(select(Paper).where(Paper.id == "p1"))).scalar_one()
            self.assertEqual(paper.status, "parsed")
            self.assertIsNone(paper.error_code)
            # Stale analysis rows were cleared before the relaunch, mirroring reparse.
            blocks = (await db.execute(select(Block).where(Block.paper_id == "p1"))).scalars().all()
            self.assertEqual(list(blocks), [])
            links = (await db.execute(select(block_entity_table.c.block_id))).all()
            self.assertEqual(list(links), [])

    async def test_no_cache_marks_interrupted_by_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            async with self.session_factory() as db:
                db.add(Paper(id="zombie", status="analyzing", mineru_output_dir="mineru_output/zombie"))
                await db.commit()
                jobs = FakeJobs()
                with patch.object(settings, "storage_root", Path(tmp)):
                    report = await reconcile_interrupted_papers(db, jobs)

            self.assertEqual(report["errored"], 1)
            self.assertEqual(jobs.submitted, [])
            paper = (await db.execute(select(Paper).where(Paper.id == "zombie"))).scalar_one()
            self.assertEqual(paper.status, "error")
            self.assertEqual(paper.error_code, "INTERRUPTED_BY_RESTART")
            self.assertIn("重新解析", paper.error_message)

    async def test_active_job_is_left_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            async with self.session_factory() as db:
                db.add(Paper(id="live", status="parsing"))
                await db.commit()
                jobs = FakeJobs()
                jobs.active.add("live")
                with patch.object(settings, "storage_root", Path(tmp)):
                    report = await reconcile_interrupted_papers(db, jobs)

            self.assertEqual(report["skipped_active"], 1)
            self.assertEqual(report["resumed"], 0)
            self.assertEqual(report["errored"], 0)
            paper = (await db.execute(select(Paper).where(Paper.id == "live"))).scalar_one()
            self.assertEqual(paper.status, "parsing")

    async def test_unreadable_content_list_counts_as_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "mineru_output" / "half"
            output.mkdir(parents=True)
            output.joinpath("content_list.json").write_text("{broken json", encoding="utf-8")
            with patch.object(settings, "storage_root", Path(tmp)):
                self.assertEqual(readable_content_list(Path(tmp) / "mineru_output" / "half"), "")
                self.assertEqual(readable_content_list(Path(tmp) / "mineru_output" / "nope"), "")
            output.joinpath("content_list.json").write_text("[]", encoding="utf-8")
            with patch.object(settings, "storage_root", Path(tmp)):
                self.assertTrue(
                    readable_content_list(Path(tmp) / "mineru_output" / "half").endswith("content_list.json")
                )


if __name__ == "__main__":
    unittest.main()
