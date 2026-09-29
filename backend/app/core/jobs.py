"""Minimal job governance for paper pipelines (agentero plan T1.1).

Long-running paper tasks go through :class:`JobCenter` instead of a bare
``BackgroundTasks.add_task``:

* per-kind semaphores cap concurrent MinerU / LLM work, so a burst of uploads
  can no longer exhaust the quotas;
* a per-paper registry powers cancellation — reparse / retranslate / delete
  cancel a paper's active jobs before touching its rows, so a stale task can
  never write Blocks behind the caller's back;
* ``CancelledError`` is re-raised untouched: cancellation is governance, not a
  failure, so no error status is ever written for a cancelled paper.

Mutex semantics for repeated submits of the same paper are the caller's
responsibility: the mutating endpoints cancel the paper's active jobs first,
and create_paper cannot collide because a paper id is freshly allocated.
"""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict

logger = logging.getLogger(__name__)

# The full pipeline runs under "mineru" (the parse is its long pole);
# "map" / "reduce" / "translate" gate the analyse-only relaunch paths.
DEFAULT_KIND_LIMITS: dict[str, int] = {
    "mineru": 2,
    "map": 2,
    "reduce": 2,
    "translate": 2,
    "figure": 2,
}


class JobCenter:
    def __init__(self, kind_limits: dict[str, int] | None = None):
        limits = dict(DEFAULT_KIND_LIMITS)
        for kind, limit in (kind_limits or {}).items():
            limits[kind] = max(1, int(limit))
        self._semaphores = {kind: asyncio.Semaphore(limit) for kind, limit in limits.items()}
        self._registry: dict[str, set[asyncio.Task]] = defaultdict(set)

    def submit(self, kind: str, paper_id: str, coro) -> asyncio.Task:
        """Schedule ``coro`` under the kind's concurrency cap."""
        semaphore = self._semaphores.setdefault(kind, asyncio.Semaphore(1))
        task = asyncio.create_task(self._run(kind, paper_id, coro, semaphore))
        # Drop finished entries before adding, so the registry only ever holds
        # live tasks even if a finally block was skipped by early cancellation.
        self._registry[paper_id] = {t for t in self._registry[paper_id] if not t.done()}
        self._registry[paper_id].add(task)
        return task

    async def _run(self, kind: str, paper_id: str, coro, semaphore: asyncio.Semaphore) -> None:
        current = asyncio.current_task()
        try:
            async with semaphore:
                await coro
        except asyncio.CancelledError:
            logger.info("job cancelled kind=%s paper=%s", kind, paper_id)
            raise
        except Exception:
            # The pipeline coroutines write their own error status; here we
            # only keep the crash visible in logs and swallow it so asyncio
            # does not emit "exception was never retrieved".
            logger.exception("job crashed kind=%s paper=%s", kind, paper_id)
        finally:
            self._registry[paper_id].discard(current)
            if not self._registry[paper_id]:
                del self._registry[paper_id]

    async def cancel_for_paper(self, paper_id: str) -> int:
        """Cancel every active job of one paper; returns the cancelled count.

        Returns only after all cancelled tasks have finished, so callers can
        safely mutate the paper's rows/files right afterwards.
        """
        tasks = [t for t in self._registry.get(paper_id, ()) if not t.done()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        return len(tasks)

    def has_active(self, paper_id: str) -> bool:
        return any(not t.done() for t in self._registry.get(paper_id, ()))

    async def cancel_all(self) -> int:
        """Shutdown hook: cancel every registered job."""
        paper_ids = [pid for pid, tasks in self._registry.items() if any(not t.done() for t in tasks)]
        for paper_id in paper_ids:
            await self.cancel_for_paper(paper_id)
        return len(paper_ids)
