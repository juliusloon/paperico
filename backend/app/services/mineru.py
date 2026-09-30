"""MinerU cloud/self-hosted API integration."""

import asyncio
import json
import uuid
import zipfile
from pathlib import Path

import httpx

from ..core.config import settings
from ..core.status import ErrorCode
from .mineru_chem import (
    MinerUChemSchemaError,
    MinerUChemUnavailable,
    find_chem_summary,
)


class MinerUServiceError(RuntimeError):
    """MinerU failure carrying the stable ErrorCode contract (core/status.py)."""

    error_code = ErrorCode.MINERU_PARSE_FAILED


class MinerUSubmitFailed(MinerUServiceError):
    error_code = ErrorCode.MINERU_SUBMIT_FAILED


class MinerUParseFailed(MinerUServiceError):
    error_code = ErrorCode.MINERU_PARSE_FAILED


class MinerUTimeout(TimeoutError):
    error_code = ErrorCode.MINERU_TIMEOUT


async def submit_task(
    file_path: str | None = None,
    pdf_url: str | None = None,
    base_url: str = "",
    api_key: str = "",
    options: dict | None = None,
) -> dict:
    """Submit a PDF parsing task using MinerU v4's current API."""
    url = (base_url or settings.mineru_base_url).rstrip("/")
    key = api_key or settings.mineru_api_key
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"

    opts = options or {}
    is_ocr = opts.get("is_ocr", True)
    enable_formula = opts.get("enable_formula", True)
    enable_table = opts.get("enable_table", True)
    language = opts.get("language", "en")
    model_backend = opts.get("model_backend", settings.mineru_model_backend)
    chem_requested = opts.get("is_chem") is True

    if pdf_url:
        payload = {
            "url": pdf_url,
            "is_ocr": is_ocr,
            "enable_formula": enable_formula,
            "enable_table": enable_table,
            "language": language,
            "model_version": model_backend,
        }
        if chem_requested:
            # This field is used by MinerU's current online Extractor, but is
            # not part of the published v4 API contract.  Only forward it
            # after an explicit opt-in and verify the separate Chem task below.
            payload["is_chem"] = True
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(f"{url}/extract/task", headers=headers, json=payload)
            resp.raise_for_status()
            body = resp.json()
            _raise_api_error(body)
            data = body.get("data", body)
            task_id = data.get("task_id", "")
            return {
                "task_id": task_id,
                "batch_id": "",
                "poll_type": "task",
                "chem_requested": chem_requested,
                "chem_task_id": task_id if chem_requested else "",
            }

    if not file_path:
        raise ValueError("MinerU requires either file_path or pdf_url")

    # Local upload: request a signed URL. Uploading automatically starts the job.
    async with httpx.AsyncClient(timeout=120) as client:
        file_name = Path(file_path).name
        data_id = f"paperico-{uuid.uuid4().hex[:12]}"
        payload = {
            "files": [{"name": file_name, "data_id": data_id, "is_ocr": is_ocr}],
            "enable_formula": enable_formula,
            "enable_table": enable_table,
            "language": language,
            "model_version": model_backend,
        }
        if chem_requested:
            payload["is_chem"] = True
        resp = await client.post(
            f"{url}/file-urls/batch",
            headers=headers,
            json=payload,
        )
        resp.raise_for_status()
        body = resp.json()
        _raise_api_error(body)
        upload_data = body.get("data", body)
        file_urls = upload_data.get("file_urls", [])
        task_ids = upload_data.get("task_ids", [])
        upload_url = file_urls[0] if file_urls else ""
        batch_id = upload_data.get("batch_id", "")
        if not upload_url or not batch_id:
            raise MinerUSubmitFailed("MinerU did not return an upload URL and batch ID")
        if chem_requested and not task_ids:
            raise MinerUChemUnavailable(
                "MinerU.Chem was requested, but file-urls/batch returned no task_ids. "
                "The configured public v4 token path accepted the normal batch without "
                "exposing a Chem task; do not treat it as Chem success."
            )
        with open(file_path, "rb") as f:
            upload_resp = await client.put(upload_url, content=f.read())
        upload_resp.raise_for_status()
        return {
            "task_id": "",
            "batch_id": batch_id,
            "poll_type": "batch",
            "chem_requested": chem_requested,
            "chem_task_id": task_ids[0] if chem_requested else "",
        }


async def poll_task(
    task_id: str,
    base_url: str = "",
    api_key: str = "",
) -> dict:
    """Poll task status. Returns {status, zip_url}."""
    url = (base_url or settings.mineru_base_url).rstrip("/")
    key = api_key or settings.mineru_api_key
    headers = {}
    if key:
        headers["Authorization"] = f"Bearer {key}"

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(f"{url}/extract/task/{task_id}", headers=headers)
        resp.raise_for_status()
        body = resp.json()
        _raise_api_error(body)
        data = body.get("data", body)
        return {
            "status": data.get("state", "pending"),
            "zip_url": data.get("full_zip_url", ""),
            "error": data.get("err_msg", ""),
        }


async def poll_batch(batch_id: str, base_url: str = "", api_key: str = "") -> dict:
    """Poll the v4 batch result endpoint used for local file uploads."""
    url = (base_url or settings.mineru_base_url).rstrip("/")
    key = api_key or settings.mineru_api_key
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(f"{url}/extract-results/batch/{batch_id}", headers=headers)
        resp.raise_for_status()
        body = resp.json()
        _raise_api_error(body)
        results = body.get("data", {}).get("extract_result", [])
        if not results:
            return {"status": "pending", "zip_url": "", "error": ""}
        item = results[0]
        return {
            "status": item.get("state", "pending"),
            "zip_url": item.get("full_zip_url", ""),
            "error": item.get("err_msg", ""),
        }


async def poll_chem_task(task_id: str, base_url: str = "", api_key: str = "") -> dict:
    """Poll the separate Chem task used by MinerU's online Extractor."""
    if not task_id:
        raise MinerUChemUnavailable("MinerU.Chem task id is missing")
    url = (base_url or settings.mineru_base_url).rstrip("/")
    key = api_key or settings.mineru_api_key
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(f"{url}/extract/task/{task_id}/chem-status", headers=headers)
        resp.raise_for_status()
        body = resp.json()
        _raise_api_error(body)
        data = body.get("data", body)
        return {
            "status": data.get("state", "pending"),
            "zip_url": data.get("zip_url", ""),
            "json_url": data.get("json_url", ""),
            "base_url": data.get("base_url", ""),
            "apicall_mol_url": data.get("apicall_mol_url", ""),
            "error": data.get("err_msg", ""),
        }


# ── Local Gradio deployment ───────────────────────────────
#
# A self-hosted MinerU (``mineru-gradio``) exposes a single Gradio endpoint
# ``/gradio_api/call/convert_to_markdown_stream`` that returns the same
# content_list/images layout as the cloud ZIP.  MinerU.Chem is cloud-only, so
# Chem options are intentionally ignored in local mode.

GRADIO_FN = "convert_to_markdown_stream"

# The Gradio language dropdown stores full labels; map Paperico's short codes.
GRADIO_LANGUAGE_LABELS = {
    "en": "ch (Chinese, English, Japanese, Chinese Traditional, Latin)",
    "ch": "ch (Chinese, English, Japanese, Chinese Traditional, Latin)",
    "japan": "ch (Chinese, English, Japanese, Chinese Traditional, Latin)",
    "korean": "korean (Korean, English)",
}
GRADIO_LANGUAGE_DEFAULT = "ch (Chinese, English, Japanese, Chinese Traditional, Latin)"


def _gradio_language_label(language: str) -> str:
    return GRADIO_LANGUAGE_LABELS.get(language, GRADIO_LANGUAGE_DEFAULT)


async def run_local_pipeline(
    file_path: str,
    base_url: str,
    options: dict | None = None,
    output_dir: str = "",
) -> tuple[list[dict], str]:
    """Parse a PDF through a locally deployed MinerU Gradio server.

    The server runs the parse synchronously inside one SSE stream, so there is
    no separate polling step.  Returns (blocks, content_list_path), matching
    the contract of :func:`run_full_pipeline`.
    """
    if not file_path:
        raise ValueError("本地 MinerU 模式只支持上传的 PDF 文件")
    url = (base_url or "http://127.0.0.1:7860").rstrip("/")
    opts = options or {}
    backend = opts.get("model_backend", "pipeline")
    if backend == "vlm":
        backend = "vlm-engine"

    async with httpx.AsyncClient(timeout=None) as client:
        with open(file_path, "rb") as f:
            upload = await client.post(
                f"{url}/gradio_api/upload",
                files={"files": (Path(file_path).name, f, "application/pdf")},
            )
        upload.raise_for_status()
        server_paths = upload.json()
        if not server_paths:
            raise MinerUSubmitFailed("本地 MinerU 上传失败：未返回服务器文件路径")

        file_data = {"path": server_paths[0], "meta": {"_type": "gradio.FileData"}}
        payload = {"data": [
            file_data,
            1000,  # end_pages
            bool(opts.get("is_ocr", False)),
            bool(opts.get("enable_formula", True)),
            bool(opts.get("enable_table", True)),
            True,  # image_analysis
            "medium",  # effort
            _gradio_language_label(str(opts.get("language", "en"))),
            backend,
            opts.get("vlm_server_url", "http://localhost:30000"),
        ]}
        call = await client.post(f"{url}/gradio_api/call/{GRADIO_FN}", json=payload)
        call.raise_for_status()
        event_id = call.json().get("event_id")
        if not event_id:
            raise MinerUSubmitFailed("本地 MinerU 未返回 event_id")

        result_data = None
        async with client.stream(
            "GET", f"{url}/gradio_api/call/{GRADIO_FN}/{event_id}"
        ) as stream:
            event = ""
            async for line in stream.aiter_lines():
                if line.startswith("event:"):
                    event = line.split(":", 1)[1].strip()
                elif line.startswith("data:"):
                    data = line[5:].strip()
                    if event == "complete":
                        result_data = json.loads(data)
                        break
                    if event == "error":
                        detail = "" if data == "null" else data
                        raise MinerUParseFailed(f"本地 MinerU 解析失败{(': ' + detail) if detail else ''}")

    if not result_data or len(result_data) < 2:
        raise MinerUParseFailed("本地 MinerU 未返回解析结果")

    zip_info = result_data[1] or {}
    zip_url = zip_info.get("url") or ""
    if zip_url and zip_url.startswith("/"):
        zip_url = url + zip_url
    if not zip_url:
        raise MinerUParseFailed("本地 MinerU 结果中缺少结果 ZIP 文件")

    content_list_path = await download_and_extract_results(zip_url, output_dir)
    if not content_list_path.endswith(".json"):
        raise MinerUParseFailed("本地 MinerU 结果不包含 content_list.json")
    blocks = parse_content_list(content_list_path)
    return blocks, content_list_path


async def download_and_extract_results(
    zip_url: str,
    output_dir: str,
) -> str:
    """Download MinerU result zip and extract to output_dir. Returns path to content_list.json."""
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    zip_path = output_path / "result.zip"

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.get(zip_url)
        resp.raise_for_status()
        zip_path.write_bytes(resp.content)

    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(output_path)

    zip_path.unlink(missing_ok=True)

    # MinerU v4 commonly prefixes the file with a task UUID, e.g.
    # "<task_id>_content_list.json".  Prefer the flat v1 schema over v2.
    content_list = find_content_list(output_path)
    if content_list:
        return content_list
    # Fallback: find any .md file
    for p in output_path.rglob("*.md"):
        return str(p)
    return str(output_path)


async def download_and_extract_chem_results(zip_url: str, output_dir: str) -> str:
    """Download a complete Chem archive and return ``demonstration_tables.json``."""
    if not zip_url:
        raise MinerUChemUnavailable("MinerU.Chem completed without a result ZIP URL")
    chem_root = Path(output_dir) / "chem"
    chem_root.mkdir(parents=True, exist_ok=True)
    zip_path = chem_root / "chem-result.zip"
    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.get(zip_url)
        resp.raise_for_status()
        zip_path.write_bytes(resp.content)
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(chem_root)
    summary_path = find_chem_summary(chem_root)
    if not summary_path:
        raise MinerUChemSchemaError(
            "MinerU.Chem result ZIP is missing demonstration_tables.json"
        )
    return summary_path


def find_content_list(output_dir: str | Path) -> str:
    """Locate MinerU's flat content list across current v4 ZIP layouts."""
    root = Path(output_dir)
    if not root.exists():
        return ""
    candidates = [
        p for p in root.rglob("*content_list.json")
        if not p.name.endswith("_content_list_v2.json")
    ]
    if not candidates:
        return ""
    candidates.sort(key=lambda p: (len(p.relative_to(root).parts), p.name))
    return str(candidates[0])


def _flatten_text(value) -> str:
    """Flatten MinerU caption/list fragments from v1/v2-compatible shapes."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return " ".join(part for item in value if (part := _flatten_text(item))).strip()
    if isinstance(value, dict):
        for key in ("text", "content", "value"):
            if key in value:
                return _flatten_text(value[key])
    return ""


def parse_content_list(content_list_path: str) -> list[dict]:
    """Parse MinerU's content_list.json into internal Block dicts."""
    with open(content_list_path, encoding="utf-8") as f:
        items = json.load(f)

    blocks = []
    order = 0
    current_section = ""

    if not isinstance(items, list):
        raise ValueError("MinerU content list must be a JSON array")

    ignored_types = {"header", "footer", "page_number", "aside_text"}
    for item in items:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type", "text")
        if item_type in ignored_types:
            continue
        if item_type == "list" and item.get("sub_type") == "ref_text":
            continue

        text = _flatten_text(item.get("text", ""))
        if item_type == "list":
            text = "\n".join(
                f"• {part}" for raw in item.get("list_items", [])
                if (part := _flatten_text(raw))
            )
        text_level = item.get("text_level", 0)
        page_idx = item.get("page_idx", None)
        bbox = item.get("bbox", None)
        img_path = item.get("img_path", "")
        table_body = item.get("table_body", "")
        caption = _flatten_text(
            item.get("image_caption")
            or item.get("chart_caption")
            or item.get("table_caption")
            or item.get("caption")
        )

        if item_type == "title" or text_level > 0:
            kind = "section_heading"
            current_section = text
        elif item_type in ("image", "chart"):
            kind = "figure"
        elif item_type == "table":
            kind = "table"
        elif item_type == "equation":
            kind = "equation"
        elif item_type == "list":
            kind = "list_item"
        else:
            kind = "paragraph"

        # Decorative publisher icons and empty layout fragments are not useful
        # reading nodes.  Keep visual blocks only when a caption is available.
        if kind in ("figure", "table") and not caption and not table_body:
            continue
        if kind not in ("figure", "table") and not text:
            continue

        served_image_path = ""
        if img_path:
            image_file = (Path(content_list_path).parent / img_path).resolve()
            try:
                served_image_path = image_file.relative_to(settings.storage_root.resolve()).as_posix()
            except ValueError:
                served_image_path = ""

        block = {
            "order": order,
            "kind": kind,
            "page_idx": page_idx,
            "bbox": bbox,
            "section_title": current_section,
            "text_original": text if kind not in ("figure", "table") else "",
            "caption_original": caption if kind in ("figure", "table") else "",
            "image_path": served_image_path,
            "table_html": table_body,
            "latex": text if kind == "equation" else "",
        }
        blocks.append(block)
        order += 1

    return blocks


async def run_full_pipeline(
    file_path: str | None = None,
    pdf_url: str | None = None,
    base_url: str = "",
    api_key: str = "",
    options: dict | None = None,
    output_dir: str = "",
    poll_interval: float = 3.0,
    max_wait: float = 600.0,
) -> tuple[list[dict], str]:
    """Run the complete MinerU pipeline: submit → poll → download → parse.
    Returns (blocks, content_list_path).
    """
    result = await submit_task(file_path, pdf_url, base_url, api_key, options)
    chem_requested = result.get("chem_requested", False)

    elapsed = 0.0
    while elapsed < max_wait:
        if result.get("poll_type") == "batch":
            status = await poll_batch(result["batch_id"], base_url, api_key)
        else:
            status = await poll_task(result["task_id"], base_url, api_key)
        if status["status"] == "done":
            if chem_requested:
                chem_status = await poll_chem_task(
                    result.get("chem_task_id", ""), base_url, api_key
                )
                if chem_status["status"] in {"failed", "aborted"}:
                    raise MinerUParseFailed(
                        f"MinerU.Chem task failed: {chem_status.get('error', 'unknown')}"
                    )
                if chem_status["status"] != "done":
                    await asyncio.sleep(poll_interval)
                    elapsed += poll_interval
                    continue
            zip_url = status["zip_url"]
            cl_path = await download_and_extract_results(zip_url, output_dir)
            if chem_requested:
                await download_and_extract_chem_results(chem_status["zip_url"], output_dir)
            if cl_path.endswith(".json"):
                blocks = parse_content_list(cl_path)
            else:
                blocks = [{"order": 0, "kind": "paragraph", "text_original": "Parsing produced non-JSON output", **{k: "" for k in ["section_title", "text_zh", "one_liner", "keywords", "image_path", "caption_original", "table_html", "latex"]}}]
            return blocks, cl_path
        elif status["status"] == "failed":
            raise MinerUParseFailed(f"MinerU task failed: {status.get('error', 'unknown')}")
        await asyncio.sleep(poll_interval)
        elapsed += poll_interval

    raise MinerUTimeout("MinerU task did not complete within time limit")


def _raise_api_error(payload: dict) -> None:
    code = payload.get("code", 0)
    if code not in (0, "0", None):
        raise MinerUSubmitFailed(f"MinerU API error {code}: {payload.get('msg', 'unknown error')}")
