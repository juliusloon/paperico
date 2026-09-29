"""Portable storage references, including paths recorded before a repo move.

Persist paths relative to storage_root. Rebase legacy absolute paths only at a
known storage directory boundary; never search by an original upload filename.
"""

from pathlib import Path, PurePosixPath

from sqlalchemy import select, update

from .config import settings


def resolve_storage_path(value: str | None, directory: str) -> Path | None:
    if not value:
        return None
    root = settings.storage_root.resolve()
    # Windows paths can also arrive in databases copied to Linux/macOS.
    parts = PurePosixPath(value.replace("\\", "/")).parts
    if ".." in parts:
        return None
    try:
        index = len(parts) - 1 - parts[::-1].index(directory)
    except ValueError:
        return None
    candidate = root.joinpath(*parts[index:]).resolve()
    if not candidate.is_relative_to(root / directory):
        return None
    return candidate


def storage_reference(path: Path) -> str:
    return path.resolve().relative_to(settings.storage_root.resolve()).as_posix()


def analyses_dir(paper_id: str) -> Path:
    """Per-paper analysis sidecar directory: storage_root/analyses/<paper_id>/."""
    return settings.storage_root / "analyses" / paper_id


def write_analysis_raw(paper_id: str, name: str, data: dict) -> bool:
    """Persist a raw LLM sidecar (map_raw.json / reduce_raw.json, T2.1).

    Best-effort by design: a sidecar write failure must never block the
    pipeline, so every error is logged and swallowed.
    """
    import json

    target = analyses_dir(paper_id) / name
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        return True
    except OSError:
        import logging

        logging.getLogger(__name__).exception(
            "failed to write analysis sidecar %s for paper %s", name, paper_id
        )
        return False


def resolve_paper_pdf(value: str | None, paper_id: str) -> Path | None:
    recorded = resolve_storage_path(value, "pdfs")
    if recorded and recorded.is_file():
        return recorded
    # IDs are allocated before upload. This also recovers missing path fields;
    # a shared legacy None.pdf is used only when explicitly recorded above.
    if not paper_id or not all(c.isalnum() or c in "-_" for c in paper_id):
        return None
    canonical = resolve_storage_path(f"pdfs/{paper_id}.pdf", "pdfs")
    return canonical if canonical and canonical.is_file() else None


async def migrate_storage_references(db) -> dict[str, int]:
    """Idempotently normalize only references whose migrated files exist."""
    from .models import Paper

    rows = (await db.execute(select(Paper.id, Paper.pdf_path, Paper.mineru_output_dir))).all()
    changed = 0
    missing = 0
    for paper_id, pdf_value, output_value in rows:
        values = {}
        pdf = resolve_paper_pdf(pdf_value, paper_id)
        if pdf:
            reference = storage_reference(pdf)
            if reference != pdf_value:
                values["pdf_path"] = reference
        elif pdf_value:
            missing += 1
        output = resolve_storage_path(output_value, "mineru_output")
        if output and output.is_dir():
            reference = storage_reference(output)
            if reference != output_value:
                values["mineru_output_dir"] = reference
        if values:
            await db.execute(update(Paper).where(Paper.id == paper_id).values(**values))
            changed += 1
    await db.commit()
    return {"papers": len(rows), "updated": changed, "missing_pdfs": missing}
