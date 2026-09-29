#!/usr/bin/env python3
"""One-shot idempotent schema/data migration for agentero-execution-plan T0+T1.

Steps (each safe to re-run):
  1. papers.error_code column (T0.1) — added via ALTER TABLE when missing.
  2. papers.file_sha256 column (T1.4) — upload dedup key, NULL for legacy rows.
  3. Fixed-width timestamps (T0.2) — every String `_at` column is rewritten to
     RFC3339 UTC milliseconds (`YYYY-MM-DDTHH:MM:SS.mmmZ`, always 24 chars) so
     SQLite string ordering can never drift.

Usage:
  python scripts/migrate_schema_v2.py            # migrate backend/paperico.db
  python scripts/migrate_schema_v2.py --db /path/to.db
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent

FIXED_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")


def database_path(explicit: str | None = None) -> Path:
    if explicit:
        return Path(explicit)
    from app.core.config import settings

    url = settings.database_url
    if ":///" in url:
        return Path(url.split(":///", 1)[1])
    return BACKEND_ROOT / "paperico.db"


def ensure_error_code_column(conn: sqlite3.Connection) -> bool:
    columns = {row[1] for row in conn.execute("PRAGMA table_info(papers)")}
    if "error_code" in columns:
        return False
    conn.execute("ALTER TABLE papers ADD COLUMN error_code VARCHAR")
    return True


def ensure_file_sha256_column(conn: sqlite3.Connection) -> bool:
    columns = {row[1] for row in conn.execute("PRAGMA table_info(papers)")}
    if "file_sha256" in columns:
        return False
    conn.execute("ALTER TABLE papers ADD COLUMN file_sha256 VARCHAR")
    return True


def parse_timestamp(value: str) -> datetime | None:
    text = value.strip()
    if FIXED_RE.match(text):
        return None  # already canonical; nothing to do
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def canonical_timestamp(value: str) -> str | None:
    """Return the fixed-width form, or None when the value must be left alone."""
    parsed = parse_timestamp(value)
    if parsed is None:
        return None
    return parsed.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def rewrite_timestamps(conn: sqlite3.Connection) -> dict[str, int]:
    changed: dict[str, int] = {}
    tables = [
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
    ]
    for table in tables:
        for row in conn.execute(f"PRAGMA table_info('{table}')"):
            column = row[1]
            if not column.endswith("_at"):
                continue
            updated = 0
            rows = conn.execute(
                f'SELECT rowid, "{column}" FROM "{table}" '
                f'WHERE "{column}" IS NOT NULL AND "{column}" != \'\''
            ).fetchall()
            for rowid, value in rows:
                if not isinstance(value, str):
                    continue
                canonical = canonical_timestamp(value)
                if canonical is None or canonical == value:
                    continue
                conn.execute(
                    f'UPDATE "{table}" SET "{column}" = ? WHERE rowid = ?',
                    (canonical, rowid),
                )
                updated += 1
            if updated:
                changed[f"{table}.{column}"] = updated
    return changed


def migrate(db_path: Path) -> dict:
    conn = sqlite3.connect(str(db_path))
    try:
        column_added = ensure_error_code_column(conn)
        sha_column_added = ensure_file_sha256_column(conn)
        timestamps = rewrite_timestamps(conn)
        conn.commit()
    finally:
        conn.close()
    return {
        "db": str(db_path),
        "error_code_column_added": column_added,
        "file_sha256_column_added": sha_column_added,
        "timestamps": timestamps,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", help="path to the SQLite database (defaults to backend settings)")
    args = parser.parse_args()

    path = database_path(args.db)
    if not path.exists():
        print(f"database not found: {path}")
        return 1

    result = migrate(path)
    print(f"database: {result['db']}")
    print(f"papers.error_code column added: {result['error_code_column_added']}")
    print(f"papers.file_sha256 column added: {result['file_sha256_column_added']}")
    if result["timestamps"]:
        print("rewritten timestamps:")
        for key, count in sorted(result["timestamps"].items()):
            print(f"  {key}: {count} rows")
    else:
        print("timestamps: already canonical")
    return 0


if __name__ == "__main__":
    sys.exit(main())
