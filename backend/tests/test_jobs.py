"""JobCenter governance regressions (agentero plan T1.1)."""

import asyncio
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import BackgroundTasks
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.api.papers import reparse_paper
from app.core.config import settings
from app.core.database import Base
from app.core.jobs import DEFAULT_KIND_LIMITS, JobCenter
from app.core.models import Block, MethodEntity, Paper, block_entity_table


def fake_request(jobs=None):
    state = SimpleNamespace()
    if jobs is not None:
        state.jobs = jobs
    return SimpleNamespace(app=SimpleNamespace(state=state))


class JobCenterTests(unittest.IsolatedAsyncioTestCase):
    async def test_kind_semaphore_caps_concurrency(self):
        center = JobCenter({"mineru": 2})
        active = 0
        peak = 0

        async def worker():
            nonlocal active, peak
            active += 1
            peak = max(peak, active)
            await asyncio.sleep(0.02)
            active -= 1

        tasks = [center.submit("mineru", f"p{i}", worker()) for i in range(6)]
        await asyncio.gather(*tasks)
        self.assertEqual(peak, 2)
        for i in range(6):
            self.assertFalse(center.has_active(f"p{i}"))

    async def test_kind_limits_default_and_override(self):
        self.assertEqual(JobCenter()._semaphores["mineru"]._value, DEFAULT_KIND_LIMITS["mineru"])
        self.assertEqual(JobCenter({"figure": 5})._semaphores["figure"]._value, 5)

    async def test_cancel_for_paper_stops_writes_and_clears_registry(self):
        center = JobCenter()
        writes = []

        async def stale_writer():
            for i in range(1000):
                writes.append(i)
                await asyncio.sleep(0)

        task = center.submit("map", "p1", stale_writer())
        await asyncio.sleep(0.01)
        self.assertTrue(center.has_active("p1"))
        cancelled = await center.cancel_for_paper("p1")
        self.assertEqual(cancelled, 1)
        self.assertTrue(task.cancelled())
        self.assertFalse(center.has_active("p1"))
        writes_at_cancel = len(writes)
        await asyncio.sleep(0.02)
        # cancel_for_paper returned only after the task died: no late writes.
        self.assertEqual(len(writes), writes_at_cancel)

    async def test_cancelled_job_cannot_write_error_status(self):
        center = JobCenter()
        state = {"status": "running"}

        async def pipeline():
            try:
                await asyncio.sleep(5)
                state["status"] = "ready"
            except Exception:
                # Mimics the pipeline's blanket except/set_paper_error: a
                # CancelledError must never land here.
                state["status"] = "error"

        task = center.submit("mineru", "p1", pipeline())
        await asyncio.sleep(0.01)
        await center.cancel_for_paper("p1")
        self.assertEqual(state["status"], "running")
        self.assertTrue(task.cancelled())

    async def test_crashing_job_is_contained_and_registry_cleans_up(self):
        center = JobCenter()

        async def crash():
            raise RuntimeError("boom")

        task = center.submit("reduce", "p3", crash())
        await task  # must not raise out of the wrapper
        self.assertIsNone(task.exception())
        self.assertFalse(center.has_active("p3"))

    async def test_has_active_tracks_lifecycle(self):
        center = JobCenter()
        started = asyncio.Event()

        async def holder():
            started.set()
            await asyncio.sleep(0.05)

        task = center.submit("translate", "p1", holder())
        await started.wait()
        self.assertTrue(center.has_active("p1"))
        await task
        self.assertFalse(center.has_active("p1"))


class ReparseCancellationTests(unittest.IsolatedAsyncioTestCase):
    """reparse must cancel the paper's active job before clearing its rows."""

    async def test_reparse_cancels_stale_job_and_clears_analysis(self):
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        try:
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            async with async_sessionmaker(engine, expire_on_commit=False)() as db:
                db.add(Paper(id="p1", status="ready", source_type="url_pdf"))
                db.add_all([
                    Block(id="b1", paper_id="p1", order=1),
                    MethodEntity(id="e1", paper_id="p1", canonical_key="k", name="k"),
                ])
                await db.flush()
                await db.execute(
                    block_entity_table.insert().values(block_id="b1", entity_id="e1")
                )
                await db.commit()

                center = JobCenter()
                writes = []
                started = asyncio.Event()

                async def stale_writer():
                    started.set()
                    for i in range(1000):
                        writes.append(i)
                        await asyncio.sleep(0)

                center.submit("mineru", "p1", stale_writer())
                await started.wait()

                launched = []

                async def fake_process(paper_id):
                    launched.append(paper_id)

                with tempfile.TemporaryDirectory() as tmp:
                    with patch("app.api.papers._process_paper", fake_process):
                        with patch.object(settings, "storage_root", Path(tmp)):
                            response = await reparse_paper(
                                "p1", fake_request(center), BackgroundTasks(), db
                            )

                self.assertEqual(response.status, "uploaded")
                await asyncio.sleep(0)
                self.assertEqual(launched, ["p1"])  # new job went through the center
                stale_writes = len(writes)
                await asyncio.sleep(0.02)
                self.assertEqual(len(writes), stale_writes)  # old coroutine stopped
                blocks = (await db.execute(select(Block).where(Block.paper_id == "p1"))).scalars().all()
                self.assertEqual(list(blocks), [])
                entities = (await db.execute(select(MethodEntity).where(MethodEntity.paper_id == "p1"))).scalars().all()
                self.assertEqual(list(entities), [])
                links = (await db.execute(select(block_entity_table.c.block_id))).all()
                self.assertEqual(list(links), [])
        finally:
            await engine.dispose()


if __name__ == "__main__":
    unittest.main()
