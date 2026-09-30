"""Recycle-bin regressions: delete-to-trash, purge, and restore (T1.3)."""

import json
import os
import shutil
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.api.papers import delete_paper
from app.core.config import settings
from app.core.database import Base
from app.core.models import Block, MethodEntity, Paper, block_entity_table
from app.core.trash import (
    move_paper_to_trash,
    purge_expired_batches,
    restore_batch,
    trash_root,
)


def fake_request(jobs=None):
    state = SimpleNamespace()
    if jobs is not None:
        state.jobs = jobs
    return SimpleNamespace(app=SimpleNamespace(state=state))


def make_paper(paper_id="p1", **overrides):
    fields = dict(
        id=paper_id,
        title="测试论文",
        status="ready",
        source_type="pdf_upload",
        pdf_path=f"pdfs/{paper_id}.pdf",
        mineru_output_dir=f"mineru_output/{paper_id}",
        created_at="2026-09-29T08:30:00.000Z",
    )
    fields.update(overrides)
    return Paper(**fields)


def write_sample_storage(root: Path, paper_id="p1"):
    """pdf + mineru tree + one orphan image outside the mineru subtree."""
    (root / "pdfs").mkdir(parents=True)
    (root / "pdfs" / f"{paper_id}.pdf").write_bytes(b"%PDF-1.4 source")
    output = root / "mineru_output" / paper_id
    (output / "images").mkdir(parents=True)
    (output / "content_list.json").write_text("[]", encoding="utf-8")
    (output / "images" / "fig.jpg").write_bytes(b"jpeg")
    (root / "images").mkdir(parents=True)
    (root / "images" / "orphan.jpg").write_bytes(b"jpeg-orphan")


class MoveToTrashTests(unittest.TestCase):
    def test_moves_files_preserving_layout_and_writes_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_sample_storage(root)
            paper = make_paper()
            blocks = [
                Block(id="b1", paper_id="p1", order=1, image_path="mineru_output/p1/images/fig.jpg"),
                Block(id="b2", paper_id="p1", order=2, image_path="images/orphan.jpg"),
                Block(id="b3", paper_id="p1", order=3),
            ]
            entities = [MethodEntity(id="e1", paper_id="p1", canonical_key="k", name="k", block_refs=["b1"])]
            with patch.object(settings, "storage_root", root):
                paper_dir = move_paper_to_trash(paper, blocks, entities)

            batch_dir = paper_dir.parent
            self.assertTrue(paper_dir.is_dir())
            self.assertEqual(paper_dir.name, "p1")
            # originals are gone
            self.assertFalse((root / "pdfs" / "p1.pdf").exists())
            self.assertFalse((root / "mineru_output" / "p1").exists())
            self.assertFalse((root / "images" / "orphan.jpg").exists())
            # layout preserved under the paper dir
            self.assertTrue((paper_dir / "pdfs" / "p1.pdf").is_file())
            self.assertTrue((paper_dir / "mineru_output" / "p1" / "content_list.json").is_file())
            self.assertTrue((paper_dir / "images" / "orphan.jpg").is_file())

            manifest = json.loads((paper_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["version"], 1)
            self.assertEqual(manifest["batch_id"], batch_dir.name)
            self.assertEqual(manifest["paper_id"], "p1")
            self.assertEqual(len(manifest["deleted_at"]), 24)
            self.assertEqual(
                sorted(manifest["files"]),
                ["images/orphan.jpg", "mineru_output/p1", "pdfs/p1.pdf"],
            )
            self.assertEqual(manifest["paper"]["title"], "测试论文")
            self.assertEqual(len(manifest["blocks"]), 3)
            self.assertEqual(len(manifest["entities"]), 1)
            self.assertEqual(manifest["blocks"][0]["image_path"], "mineru_output/p1/images/fig.jpg")

    def test_failed_move_restores_everything_and_removes_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_sample_storage(root)
            paper = make_paper()
            original_move = shutil.move
            calls = {"n": 0}

            def flaky_move(src, dst, *args, **kwargs):
                calls["n"] += 1
                if calls["n"] == 2:
                    raise OSError("disk on fire")
                return original_move(src, dst, *args, **kwargs)

            with patch.object(settings, "storage_root", root):
                with patch("app.core.trash.shutil.move", side_effect=flaky_move):
                    with self.assertRaises(OSError):
                        move_paper_to_trash(paper, [Block(id="b1", paper_id="p1", order=1)], [])

                # everything back at its original place, batch gone
                self.assertTrue((root / "pdfs" / "p1.pdf").is_file())
                self.assertTrue((root / "mineru_output" / "p1" / "content_list.json").is_file())
                self.assertEqual(list(trash_root().iterdir()), [])


class PurgeTests(unittest.TestCase):
    def test_only_batches_older_than_retention_are_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(settings, "storage_root", root):
                old_batch = trash_root() / "old-batch"
                new_batch = trash_root() / "new-batch"
                for batch in (old_batch, new_batch):
                    (batch / "p1").mkdir(parents=True)
                    (batch / "p1" / "manifest.json").write_text("{}", encoding="utf-8")
                stamp = (datetime.now(UTC) - timedelta(days=9)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
                (old_batch / "p1" / "manifest.json").write_text(
                    json.dumps({"deleted_at": stamp}), encoding="utf-8"
                )
                # manifest-less batch falls back to directory mtime
                naked = trash_root() / "naked-batch" / "p2"
                naked.mkdir(parents=True)
                old = (datetime.now(UTC) - timedelta(days=30)).timestamp()
                os.utime(trash_root() / "naked-batch", (old, old))

                purged = purge_expired_batches(retention_days=7)

            self.assertEqual(purged, ["naked-batch", "old-batch"])
            self.assertTrue(new_batch.is_dir())
            self.assertFalse(old_batch.exists())
            self.assertFalse(naked.exists())


class DeleteAndRestoreTests(unittest.IsolatedAsyncioTestCase):
    async def test_delete_endpoint_cancels_moves_and_restores(self):
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        try:
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            session_factory = async_sessionmaker(engine, expire_on_commit=False)

            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                write_sample_storage(root)
                async with session_factory() as db:
                    db.add(make_paper())
                    db.add_all([
                        Block(id="b1", paper_id="p1", order=1, image_path="mineru_output/p1/images/fig.jpg"),
                        Block(id="b2", paper_id="p1", order=2, image_path="images/orphan.jpg"),
                        MethodEntity(id="e1", paper_id="p1", canonical_key="k", name="k", block_refs=["b1", "b2"]),
                    ])
                    await db.flush()
                    await db.execute(
                        block_entity_table.insert().values(
                            [{"block_id": "b1", "entity_id": "e1"}, {"block_id": "b2", "entity_id": "e1"}]
                        )
                    )
                    await db.commit()

                    with patch.object(settings, "storage_root", root):
                        result = await delete_paper("p1", fake_request(), db)

                    self.assertEqual(result, {"ok": True})
                    self.assertIsNone(await db.get(Paper, "p1"))
                    self.assertEqual(
                        list((await db.execute(select(Block))).scalars()), []
                    )
                    self.assertEqual(
                        list((await db.execute(select(MethodEntity))).scalars()), []
                    )
                    self.assertEqual(list((await db.execute(select(block_entity_table.c.block_id))).all()), [])
                    self.assertFalse((root / "pdfs" / "p1.pdf").exists())

                # ── restore through the script entry point ──
                with patch.object(settings, "storage_root", root):
                    batch_id = next(iter(trash_root().iterdir())).name
                async with session_factory() as db:
                    with patch.object(settings, "storage_root", root):
                        report = await restore_batch(db, batch_id)
                self.assertEqual(report["restored"], ["p1"])
                async with session_factory() as db:
                    paper = await db.get(Paper, "p1")
                    self.assertEqual(paper.title, "测试论文")
                    self.assertEqual(paper.file_sha256, None)
                    block1 = await db.get(Block, "b1")
                    self.assertEqual(block1.image_path, "mineru_output/p1/images/fig.jpg")
                    entity = await db.get(MethodEntity, "e1")
                    self.assertEqual(entity.block_refs, ["b1", "b2"])
                    links = [row[0] for row in (await db.execute(select(block_entity_table.c.block_id))).all()]
                    self.assertEqual(sorted(links), ["b1", "b2"])
                    # files returned to their original locations
                    self.assertTrue((root / "pdfs" / "p1.pdf").is_file())
                    self.assertTrue((root / "mineru_output" / "p1" / "content_list.json").is_file())
                    self.assertTrue((root / "images" / "orphan.jpg").is_file())

                    # restoring again skips the existing paper
                    with patch.object(settings, "storage_root", root):
                        second = await restore_batch(db, batch_id)
                    self.assertEqual(second["skipped"], ["p1"])
                    self.assertEqual(second["restored"], [])
        finally:
            await engine.dispose()

    async def test_delete_unknown_paper_404(self):
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        try:
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            async with async_sessionmaker(engine, expire_on_commit=False)() as db:
                with self.assertRaises(HTTPException) as caught:
                    await delete_paper("missing", fake_request(), db)
                self.assertEqual(caught.exception.status_code, 404)
        finally:
            await engine.dispose()


if __name__ == "__main__":
    unittest.main()
