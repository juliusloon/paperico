#!/usr/bin/env python3
"""Restore deleted papers from the recycle bin (agentero plan T1.3, no UI).

Moves the batch's files back to their original storage locations and rebuilds
the Paper/Block/Entity rows from manifest.json. Papers whose id already exists
are skipped. The manifest stays in place for audit.

Usage:
  python scripts/restore_from_trash.py <batch_id>
  python scripts/restore_from_trash.py --list
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.core.database import async_session  # noqa: E402
from app.core.trash import restore_batch, trash_root  # noqa: E402


def list_batches() -> None:
    root = trash_root()
    if not root.is_dir():
        print("recycle bin is empty")
        return
    import json

    for batch_dir in sorted(root.iterdir()):
        if not batch_dir.is_dir():
            continue
        papers = [p.name for p in batch_dir.iterdir() if p.is_dir()]
        print(f"{batch_dir.name}  papers={','.join(papers) or '-'}")


async def restore(batch_id: str) -> int:
    async with async_session() as db:
        result = await restore_batch(db, batch_id)
    print(f"batch {result['batch_id']}: restored={result['restored'] or '-'} skipped={result['skipped'] or '-'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("batch_id", nargs="?", help="batch id as shown by --list")
    parser.add_argument("--list", action="store_true", help="list available batches")
    args = parser.parse_args()
    if args.list or not args.batch_id:
        list_batches()
        return 0 if args.list else 1
    return asyncio.run(restore(args.batch_id))


if __name__ == "__main__":
    sys.exit(main())
