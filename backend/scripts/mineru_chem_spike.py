#!/usr/bin/env python3
"""Reproduce the MinerU.Chem integration spike without exposing credentials."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx


BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.services import mineru  # noqa: E402
from app.services.mineru_chem import (  # noqa: E402
    MinerUChemUnavailable,
    inspect_chem_bundle,
)


DEFAULT_BASE_URL = "https://mineru.net/api/v4"
DEFAULT_DEMO_ID = "demo-6d1a-411e-8092-3f41910f4829"


def _print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def _safe_extract(archive_path: Path, output_dir: Path) -> None:
    output_root = output_dir.resolve()
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            destination = (output_root / member.filename).resolve()
            if output_root not in destination.parents and destination != output_root:
                raise RuntimeError(f"Unsafe path in Chem ZIP: {member.filename}")
        archive.extractall(output_root)


async def _download_demo(args: argparse.Namespace) -> int:
    output = args.output.resolve()
    archive_path = output / "chem-result.zip"
    extracted = output / "extracted"
    if archive_path.exists() or extracted.exists():
        raise RuntimeError(
            f"Output already contains spike artifacts: {output}. Choose a new directory."
        )
    output.mkdir(parents=True, exist_ok=True)

    status_url = f"{args.base_url.rstrip('/')}/demo-chem/{args.demo_id}/"
    async with httpx.AsyncClient(timeout=120, follow_redirects=True) as client:
        status_response = await client.get(status_url)
        status_response.raise_for_status()
        envelope = status_response.json()
        if envelope.get("code") not in (0, "0", None):
            raise RuntimeError(
                f"MinerU demo API error {envelope.get('code')}: "
                f"{envelope.get('msg', 'unknown error')}"
            )
        status = envelope.get("data", envelope)
        if status.get("state") != "done" or not status.get("zip_url"):
            raise RuntimeError(f"Chem demo is not downloadable: {status.get('state')}")
        archive_response = await client.get(status["zip_url"])
        archive_response.raise_for_status()
        archive_path.write_bytes(archive_response.content)

    extracted.mkdir()
    _safe_extract(archive_path, extracted)
    audit = inspect_chem_bundle(extracted)
    archive_bytes = archive_path.read_bytes()
    manifest = {
        "schema_version": 1,
        "downloaded_at": datetime.now(timezone.utc).isoformat(),
        "source_kind": "official_public_chem_demo",
        "status_endpoint": status_url,
        "demo_id": args.demo_id,
        "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
        "archive_size": len(archive_bytes),
        "audit": audit,
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _print_json(manifest)
    return 0


async def _probe_api(args: argparse.Namespace) -> int:
    api_key = os.environ.get(args.api_key_env, "").strip()
    if not api_key:
        raise RuntimeError(
            f"Missing API token in environment variable {args.api_key_env}"
        )
    try:
        result = await mineru.submit_task(
            file_path=str(args.pdf.resolve()),
            base_url=args.base_url,
            api_key=api_key,
            options={
                "is_chem": True,
                "is_ocr": args.ocr,
                "enable_formula": True,
                "enable_table": True,
                "language": args.language,
                "model_backend": args.model_version,
            },
        )
    except MinerUChemUnavailable as exc:
        _print_json(
            {
                "chem_task_created": False,
                "reason": str(exc),
                "base_url": args.base_url,
            }
        )
        return 2

    _print_json(
        {
            "chem_task_created": bool(result.get("chem_task_id")),
            "task_id": result.get("chem_task_id", ""),
            "batch_id": result.get("batch_id", ""),
            "poll_type": result.get("poll_type", ""),
        }
    )
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser(
        "inspect", help="validate and summarize an extracted Chem bundle"
    )
    inspect_parser.add_argument("path", type=Path)

    demo_parser = subparsers.add_parser(
        "download-demo", help="download the official public Chem demo bundle"
    )
    demo_parser.add_argument("--output", required=True, type=Path)
    demo_parser.add_argument("--demo-id", default=DEFAULT_DEMO_ID)
    demo_parser.add_argument("--base-url", default=DEFAULT_BASE_URL)

    probe_parser = subparsers.add_parser(
        "probe-api", help="submit a PDF with the web client's hidden is_chem flag"
    )
    probe_parser.add_argument("pdf", type=Path)
    probe_parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    probe_parser.add_argument("--api-key-env", default="MINERU_API_KEY")
    probe_parser.add_argument("--language", default="en")
    probe_parser.add_argument("--model-version", default="pipeline")
    probe_parser.add_argument("--ocr", action="store_true")
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    if args.command == "inspect":
        _print_json(inspect_chem_bundle(args.path))
        return 0
    if args.command == "download-demo":
        return asyncio.run(_download_demo(args))
    if args.command == "probe-api":
        return asyncio.run(_probe_api(args))
    raise AssertionError(f"Unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
