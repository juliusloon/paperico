"""Startup reconcile: self-heal papers stuck in an in-flight status (T1.2).

A kill -9 (or crash) between job submission and completion leaves rows parked
in parsing/normalizing/analyzing/reducing forever. On startup, every such
paper without a live job is reconciled:

* a readable MinerU content list exists → reset to ``parsed`` and relaunch the
  cached-parse path (same resume semantics as ``POST /{id}/reparse``,
  including clearing the stale analysis rows so blocks cannot duplicate);
* otherwise → mark ``error`` with ``INTERRUPTED_BY_RESTART`` so the UI can
  offer a one-click reparse instead of an eternal spinner.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import noload

from ..core.models import Paper
from ..core.status import ErrorCode, PaperStatus, PipelineError, set_paper_error
from ..core.storage import resolve_storage_path
from ..services import mineru

logger = logging.getLogger(__name__)

IN_FLIGHT_STATUSES = (
    PaperStatus.PARSING,
    PaperStatus.NORMALIZING,
    PaperStatus.ANALYZING,
    PaperStatus.REDUCING,
)


def readable_content_list(output_dir) -> str:
    """Return the content-list path only when it exists and parses as JSON."""
    path = mineru.find_content_list(output_dir) if output_dir else ""
    if not path:
        return ""
    try:
        json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return path


async def reconcile_interrupted_papers(db, jobs) -> dict[str, int]:
    """Resume or error-out every in-flight paper; runs once from lifespan."""
    # The pipeline lives in the api layer; imported at call time both to avoid
    # an api→services→api cycle and so tests can patch the module attribute.
    from ..api.papers import _clear_paper_analysis, _process_paper

    rows = list(
        (
            await db.execute(
                select(Paper)
                .where(Paper.status.in_(IN_FLIGHT_STATUSES))
                .options(
                    noload(Paper.project),
                    noload(Paper.blocks),
                    noload(Paper.entities),
                    noload(Paper.chat_sessions),
                    noload(Paper.notes),
                )
            )
        ).scalars()
    )
    resumed = errored = skipped = 0
    for paper in rows:
        if jobs.has_active(paper.id):
            skipped += 1
            continue
        output_dir = resolve_storage_path(paper.mineru_output_dir, "mineru_output")
        if readable_content_list(output_dir):
            # Same contract as reparse: drop partial analysis rows first so
            # the resumed run cannot duplicate blocks or entity links.
            await _clear_paper_analysis(db, paper.id)
            paper.status = PaperStatus.PARSED
            paper.error_message = ""
            paper.error_code = None
            await db.commit()
            jobs.submit("map", paper.id, _process_paper(paper.id))
            resumed += 1
        else:
            set_paper_error(
                paper,
                PipelineError("服务重启导致解析中断，请重新解析", ErrorCode.INTERRUPTED_BY_RESTART),
            )
            await db.commit()
            errored += 1
    report = {"in_flight": len(rows), "resumed": resumed, "errored": errored, "skipped_active": skipped}
    logger.info("startup reconcile: %s", report)
    return report
