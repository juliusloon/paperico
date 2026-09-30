"""Read-only audit of local source PDFs and the running file endpoint."""

import argparse
import asyncio
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import httpx
from sqlalchemy import select

from app.core.config import settings
from app.core.database import async_session
from app.core.models import Block, Paper
from app.core.storage import resolve_paper_pdf, resolve_storage_path


async def audit(base_url: str) -> dict:
    async with async_session() as db:
        rows = (await db.execute(select(Paper.id, Paper.pdf_path, Paper.mineru_output_dir))).all()
        images = (await db.execute(select(Block.image_path).where(Block.image_path != ""))).scalars().all()
    results = []
    async with httpx.AsyncClient(base_url=base_url, timeout=30) as client:
        for paper_id, value, output_value in rows:
            pdf = resolve_paper_pdf(value, paper_id)
            output = resolve_storage_path(output_value, "mineru_output")
            result = {"id": paper_id, "pdf_path": value, "resolved": bool(pdf)}
            response = await client.get(f"/api/papers/{paper_id}/pdf")
            partial = await client.get(f"/api/papers/{paper_id}/pdf", headers={"Range": "bytes=0-4"})
            digest = hashlib.sha256(pdf.read_bytes()).hexdigest() if pdf else None
            result.update(
                http_status=response.status_code,
                sha256=digest,
                bytes_match=digest == hashlib.sha256(response.content).hexdigest(),
                pdf_header=response.content.startswith(b"%PDF-"),
                range_ok=partial.status_code == 206 and partial.content == b"%PDF-",
                output_exists=bool(output and output.is_dir()),
                relative_paths=bool(value and not Path(value).is_absolute() and not Path(output_value or "").is_absolute()),
            )
            result["passed"] = response.status_code == 200 and all(result[key] for key in ("bytes_match", "pdf_header", "range_ok", "relative_paths"))
            results.append(result)
    return {
        "papers": len(rows), "passed": sum(item["passed"] for item in results),
        "image_count": len(images),
        "missing_images": [value for value in images if not (settings.storage_root / value).is_file()],
        "results": results,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "docs/verification/pdf-audit.json")
    args = parser.parse_args()
    report = asyncio.run(audit(args.base_url))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "results"}))
    sys.exit(0 if report["passed"] == report["papers"] and not report["missing_images"] else 1)
