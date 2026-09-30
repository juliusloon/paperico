"""Recycle bin for deleted papers (agentero plan T1.3).

Delete flow (see ``api/papers.py::delete_paper``): cancel the paper's jobs,
move its files into ``storage_root/.trash/<batch_id>/<paper_id>/`` preserving
their storage-relative layout, and write ``manifest.json`` holding the
paper/block/entity rows plus the original relative paths and ``deleted_at``.
Only then are the DB rows dropped. Batches older than ``trash_retention_days``
are purged on startup; recovery is a script
(``scripts/restore_from_trash.py``), deliberately not a UI.
"""

from __future__ import annotations

import json
import shutil
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import insert

from .config import settings
from .models import Block, MethodEntity, Paper, _now, block_entity_table
from .storage import resolve_paper_pdf, resolve_storage_path, storage_reference

MANIFEST_NAME = "manifest.json"
MANIFEST_VERSION = 1

PAPER_FIELDS = (
    "id", "project_id", "title", "title_zh", "authors", "year", "venue",
    "source_type", "source_url", "original_file_name", "domain_tags", "tldr",
    "narrative_summary", "contributions", "difficulty_estimate", "status",
    "error_message", "error_code", "reading_progress", "mineru_task_id",
    "created_at", "updated_at", "last_opened_at", "pdf_path",
    "mineru_output_dir", "file_sha256",
)
BLOCK_FIELDS = (
    "id", "paper_id", "order", "kind", "page_idx", "bbox", "section_title",
    "text_original", "text_zh", "one_liner", "keywords", "role_in_narrative",
    "image_path", "caption_original", "caption_zh", "figure_type",
    "core_takeaways", "data_reading_notes", "table_html", "latex",
    "plain_explanation",
)
ENTITY_FIELDS = (
    "id", "paper_id", "canonical_key", "name", "category", "definition_zh",
    "block_refs",
)


def trash_root() -> Path:
    return settings.storage_root / ".trash"


def new_batch_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:4]


def _row(row, fields) -> dict:
    return {name: getattr(row, name) for name in fields}


def paper_file_references(paper: Paper, blocks) -> list[tuple[Path, str]]:
    """(absolute source, storage-relative path) for every file worth trashing.

    Figures live inside the MinerU output tree, so moving that directory
    covers them; any block image outside it is collected individually.
    """
    refs: list[tuple[Path, str]] = []
    pdf = resolve_paper_pdf(paper.pdf_path, paper.id)
    if pdf and pdf.is_file():
        refs.append((pdf, storage_reference(pdf)))
    output_dir = resolve_storage_path(paper.mineru_output_dir, "mineru_output")
    if output_dir and output_dir.is_dir():
        refs.append((output_dir, storage_reference(output_dir)))
    covered = [settings.storage_root / rel for source, rel in refs if source.is_dir()]
    seen = {rel for _, rel in refs}
    root = settings.storage_root.resolve()
    for block in blocks:
        rel = (block.image_path or "").strip()
        if not rel or rel in seen:
            continue
        source = (settings.storage_root / rel).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            continue
        if any(source.is_relative_to(cover.resolve()) for cover in covered):
            continue
        refs.append((source, rel))
        seen.add(rel)
    return refs


def move_paper_to_trash(paper: Paper, blocks, entities) -> Path:
    """Move the paper's files into a fresh trash batch and write manifest.json.

    Returns the paper's directory inside ``.trash``. If a move fails midway,
    everything already moved is restored to its original location, the batch
    is removed, and the exception propagates so the caller keeps the DB rows
    (a delete must never lose data it could not stage).
    """
    batch_dir = trash_root() / new_batch_id()
    paper_dir = batch_dir / paper.id
    references = paper_file_references(paper, blocks)
    moved: list[tuple[Path, Path]] = []
    try:
        for source, rel in references:
            target = paper_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(target))
            moved.append((source, target))
        manifest = {
            "version": MANIFEST_VERSION,
            "batch_id": batch_dir.name,
            "paper_id": paper.id,
            "deleted_at": _now(),
            "files": [rel for _, rel in references],
            "paper": _row(paper, PAPER_FIELDS),
            "blocks": [_row(b, BLOCK_FIELDS) for b in blocks],
            "entities": [_row(e, ENTITY_FIELDS) for e in entities],
        }
        paper_dir.mkdir(parents=True, exist_ok=True)
        (paper_dir / MANIFEST_NAME).write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    except Exception:
        for source, target in reversed(moved):
            source.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(source))
        shutil.rmtree(batch_dir, ignore_errors=True)
        raise
    # Drop parents the paper was the sole occupant of (e.g. mineru_output/).
    for _, rel in references:
        parent = (settings.storage_root / rel).parent
        while parent != settings.storage_root and parent.is_dir() and not any(parent.iterdir()):
            parent.rmdir()
            parent = parent.parent
    return paper_dir


def _batch_time(batch_dir: Path) -> float:
    # manifest.json lives one level down, inside each paper directory
    for paper_dir in batch_dir.iterdir():
        manifest = paper_dir / MANIFEST_NAME
        if not manifest.is_file():
            continue
        try:
            deleted_at = json.loads(manifest.read_text(encoding="utf-8")).get("deleted_at")
            if deleted_at:
                return datetime.fromisoformat(deleted_at.replace("Z", "+00:00")).timestamp()
        except (OSError, ValueError):
            pass
    return batch_dir.stat().st_mtime


def purge_expired_batches(retention_days: int | None = None) -> list[str]:
    """Remove trash batches older than the retention window; returns batch ids."""
    days = settings.trash_retention_days if retention_days is None else retention_days
    root = trash_root()
    if not root.is_dir() or days <= 0:
        return []
    cutoff = time.time() - days * 86400
    purged: list[str] = []
    for batch_dir in sorted(root.iterdir()):
        if not batch_dir.is_dir():
            continue
        if _batch_time(batch_dir) >= cutoff:
            continue
        shutil.rmtree(batch_dir, ignore_errors=True)
        purged.append(batch_dir.name)
    return purged


def _move_files_back(paper_dir: Path, relative_paths) -> list[str]:
    moved: list[str] = []
    for rel in relative_paths:
        source = paper_dir / rel
        target = settings.storage_root / rel
        if not source.exists() or target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(target))
        moved.append(rel)
    return moved


async def restore_batch(db, batch_id: str) -> dict:
    """Rebuild Paper/Block/Entity rows of a trash batch and move files back.

    Skips papers whose id already exists (the user re-created them); existing
    target files are never overwritten.
    """
    batch_dir = trash_root() / batch_id
    if not batch_dir.is_dir():
        raise FileNotFoundError(f"trash batch not found: {batch_id}")
    restored: list[str] = []
    skipped: list[str] = []
    for paper_dir in sorted(p for p in batch_dir.iterdir() if p.is_dir()):
        manifest_path = paper_dir / MANIFEST_NAME
        if not manifest_path.is_file():
            continue
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        paper_payload = manifest.get("paper", {})
        paper_id = paper_payload.get("id", paper_dir.name)
        if await db.get(Paper, paper_id):
            skipped.append(paper_id)
            continue
        moved = _move_files_back(paper_dir, manifest.get("files", []))
        db.add(Paper(**{f: paper_payload[f] for f in PAPER_FIELDS if f in paper_payload}))
        for row in manifest.get("blocks", []):
            db.add(Block(**{f: row[f] for f in BLOCK_FIELDS if f in row}))
        entities = manifest.get("entities", [])
        for row in entities:
            db.add(MethodEntity(**{f: row[f] for f in ENTITY_FIELDS if f in row}))
        await db.flush()
        block_ids = {row["id"] for row in manifest.get("blocks", [])}
        associations = [
            {"block_id": block_id, "entity_id": row["id"]}
            for row in entities
            for block_id in row.get("block_refs", [])
            if block_id in block_ids
        ]
        if associations:
            await db.execute(insert(block_entity_table), associations)
        restored.append(paper_id)
        if moved:
            manifest["restored_files"] = moved
            manifest_path.write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
            )
    await db.commit()
    return {"batch_id": batch_id, "restored": restored, "skipped": skipped}
