"""Paper ingestion, parsing, and status endpoints."""

import asyncio
import hashlib
import uuid
from datetime import UTC
from pathlib import Path

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
)
from fastapi.responses import FileResponse
from sqlalchemy import insert, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import noload

from ..core.config import settings
from ..core.crypto import decrypt_or_empty
from ..core.database import get_db
from ..core.models import (
    AppSettingsModel,
    Block,
    MethodEntity,
    Paper,
    ProjectGroup,
    _now,
    block_entity_table,
)
from ..core.schemas import (
    BlockOut,
    EntityOut,
    PaperDetail,
    PaperListItem,
    PaperMoveRequest,
    PaperRenameRequest,
    PaperStatusOut,
)
from ..core.status import ErrorCode, PipelineError, set_paper_error
from ..core.storage import (
    resolve_paper_pdf,
    resolve_storage_path,
    storage_reference,
    write_analysis_raw,
)
from ..core.trash import move_paper_to_trash
from ..services import analysis, mineru
from ..services.llm import LLMClient
from ..services.profiles import LlmRole, resolve_llm

router = APIRouter()

# Streamed upload chunk size for the sha256 digest (T1.4).
_UPLOAD_CHUNK = 1 << 20


def _job_center(request: Request):
    return getattr(request.app.state, "jobs", None)


def _launch(request: Request, background_tasks: BackgroundTasks, kind: str, paper_id: str, func, /, *args) -> None:
    """Run a pipeline task through the JobCenter, or fall back to the legacy
    BackgroundTasks path when ``use_job_center`` is switched off."""
    jobs = _job_center(request)
    if settings.use_job_center and jobs is not None:
        jobs.submit(kind, paper_id, func(*args))
    else:
        background_tasks.add_task(func, *args)


def _paper_item(p: Paper) -> PaperListItem:
    return PaperListItem(
        id=p.id, title=p.title, title_zh=p.title_zh,
        authors=p.authors or [], year=p.year,
        domain_tags=p.domain_tags or [], status=p.status,
        project_id=p.project_id, source_type=p.source_type,
        original_file_name=p.original_file_name or "",
        created_at=p.created_at, last_opened_at=p.last_opened_at,
        tldr=p.tldr or "", narrative_summary=p.narrative_summary or "",
        contributions=p.contributions or [], difficulty_estimate=p.difficulty_estimate or "",
        venue=p.venue or "",
        error_message=p.error_message or "",
        error_code=p.error_code or "",
    )


@router.post("", response_model=PaperListItem)
async def create_paper(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(None),
    project_id: str | None = Form(None),
    source_url: str | None = Form(None),
    db: AsyncSession = Depends(get_db),
):
    # SQLAlchemy defaults are assigned on INSERT, which is too late for naming
    # the uploaded file.  Allocate the id before writing the PDF.
    paper = Paper(id=uuid.uuid4().hex[:12], project_id=project_id, source_url=source_url or "")

    if file:
        if not (file.filename or "").lower().endswith(".pdf"):
            raise HTTPException(400, "Only PDF files are supported")
        paper.source_type = "pdf_upload"
        paper.original_file_name = file.filename or "upload.pdf"
        # Save PDF, hashing it while streaming so duplicates are caught before
        # any MinerU/LLM quota is spent (T1.4).
        pdf_dir = settings.storage_root / "pdfs"
        pdf_dir.mkdir(parents=True, exist_ok=True)
        pdf_path = pdf_dir / f"{paper.id}.pdf"
        first = await file.read(_UPLOAD_CHUNK)
        if not first.startswith(b"%PDF-"):
            raise HTTPException(400, "The uploaded file is not a valid PDF")
        hasher = hashlib.sha256(first)
        with pdf_path.open("wb") as sink:
            sink.write(first)
            while chunk := await file.read(_UPLOAD_CHUNK):
                hasher.update(chunk)
                sink.write(chunk)
        paper.file_sha256 = hasher.hexdigest()
        duplicate = (
            await db.execute(
                select(Paper)
                .where(Paper.file_sha256 == paper.file_sha256)
                .options(
                    noload(Paper.project),
                    noload(Paper.blocks),
                    noload(Paper.entities),
                    noload(Paper.chat_sessions),
                    noload(Paper.notes),
                )
            )
        ).scalars().first()
        if duplicate:
            pdf_path.unlink(missing_ok=True)
            label = duplicate.title or duplicate.original_file_name or duplicate.id
            raise HTTPException(409, f"与已有论文《{label}》重复（id {duplicate.id}）")
        paper.pdf_path = storage_reference(pdf_path)
    elif source_url:
        if source_url.endswith(".pdf") or "/pdf/" in source_url:
            paper.source_type = "url_pdf"
        else:
            paper.source_type = "url_html"
        paper.original_file_name = source_url.split("/")[-1][:100]
    else:
        raise HTTPException(400, "Either file or source_url required")

    db.add(paper)
    await db.commit()
    await db.refresh(paper)

    # Start background processing
    _launch(request, background_tasks, "mineru", paper.id, _process_paper, paper.id)

    return _paper_item(paper)


@router.get("", response_model=list[PaperListItem])
async def list_papers(
    project_id: str | None = None,
    status: str | None = None,
    q: str | None = None,
    db: AsyncSession = Depends(get_db),
):
    # Library cards only use paper metadata. Explicitly suppress relationship
    # loading so a library refresh does not hydrate thousands of parsed blocks.
    query = select(Paper).options(
        noload(Paper.project),
        noload(Paper.blocks),
        noload(Paper.entities),
        noload(Paper.chat_sessions),
        noload(Paper.notes),
    )
    if project_id:
        query = query.where(Paper.project_id == project_id)
    if status:
        query = query.where(Paper.status == status)
    if q:
        query = query.where(Paper.title.contains(q) | Paper.original_file_name.contains(q))
    query = query.order_by(Paper.created_at.desc())
    result = await db.execute(query)
    return [_paper_item(p) for p in result.scalars().all()]


@router.patch("/project")
async def move_papers_to_project(data: PaperMoveRequest, db: AsyncSession = Depends(get_db)):
    """Move one or many papers into a project, or clear their grouping."""
    if data.project_id:
        project = await db.get(ProjectGroup, data.project_id)
        if not project:
            raise HTTPException(404, "Project not found")

    result = await db.execute(
        select(Paper)
        .where(Paper.id.in_(data.paper_ids))
        .options(
            noload(Paper.project),
            noload(Paper.blocks),
            noload(Paper.entities),
            noload(Paper.chat_sessions),
            noload(Paper.notes),
        )
    )
    papers = list(result.scalars().all())
    for paper in papers:
        paper.project_id = data.project_id
    await db.commit()
    return {"ok": True, "moved": len(papers), "project_id": data.project_id}


@router.patch("/{paper_id}/title", response_model=PaperListItem)
async def rename_paper(paper_id: str, data: PaperRenameRequest, db: AsyncSession = Depends(get_db)):
    """Rename a paper's title."""
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    paper.title = data.title
    await db.commit()
    await db.refresh(paper)
    return _paper_item(paper)


@router.get("/{paper_id}", response_model=PaperDetail)
async def get_paper(paper_id: str, db: AsyncSession = Depends(get_db)):
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    # Update last opened
    from datetime import datetime
    paper.last_opened_at = datetime.now(UTC).isoformat()
    await db.commit()

    blocks_result = await db.execute(
        select(Block).where(Block.paper_id == paper_id).order_by(Block.order)
    )
    blocks = blocks_result.scalars().all()

    entities_result = await db.execute(
        select(MethodEntity).where(MethodEntity.paper_id == paper_id)
    )
    entities = entities_result.scalars().all()

    # Build entity refs for each block
    block_outs = []
    for b in blocks:
        entity_refs = [e.id for e in b.entities] if hasattr(b, 'entities') and b.entities else []
        block_outs.append(BlockOut(
            id=b.id, order=b.order, kind=b.kind, page_idx=b.page_idx,
            bbox=b.bbox,
            section_title=b.section_title or "", text_original=b.text_original or "",
            text_zh=b.text_zh or "", one_liner=b.one_liner or "",
            keywords=b.keywords or [], role_in_narrative=b.role_in_narrative or "",
            image_path=b.image_path or "", caption_original=b.caption_original or "",
            caption_zh=b.caption_zh or "", figure_type=b.figure_type or "",
            core_takeaways=b.core_takeaways or [], data_reading_notes=b.data_reading_notes or "",
            table_html=b.table_html or "", latex=b.latex or "",
            plain_explanation=b.plain_explanation or "", entity_refs=entity_refs,
        ))

    entity_outs = [
        EntityOut(
            id=e.id, canonical_key=e.canonical_key, name=e.name,
            category=e.category, definition_zh=e.definition_zh or "",
            block_refs=e.block_refs or [],
        )
        for e in entities
    ]

    return PaperDetail(
        paper=_paper_item(paper),
        blocks=block_outs,
        entities=entity_outs,
    )


@router.get("/{paper_id}/pdf")
async def get_paper_pdf(paper_id: str, db: AsyncSession = Depends(get_db)):
    """Stream the uploaded source PDF for the in-app canvas reader."""
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    pdf_path = resolve_paper_pdf(paper.pdf_path, paper.id)
    if not pdf_path:
        raise HTTPException(404, "未找到这篇论文的原始 PDF，请检查存储目录中的源文件是否已一同迁移。")
    return FileResponse(
        path=pdf_path,
        media_type="application/pdf",
        filename=paper.original_file_name or f"{paper.id}.pdf",
        content_disposition_type="inline",
    )


@router.get("/{paper_id}/status", response_model=PaperStatusOut)
async def get_paper_status(paper_id: str, db: AsyncSession = Depends(get_db)):
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    return PaperStatusOut(id=paper.id, status=paper.status, error_message=paper.error_message or "", error_code=paper.error_code or "")


async def _clear_paper_analysis(db: AsyncSession, paper_id: str) -> None:
    """Delete a paper's blocks and entities (and their association rows via
    the secondary table) so a fresh run cannot collide with stale data.

    ORM-level deletes on purpose: loaded Block rows must be marked deleted in
    the session, or a later ``db.delete(paper)`` would try to nullify the
    already-gone children (StaleDataError).
    """
    blocks = (await db.execute(select(Block).where(Block.paper_id == paper_id))).scalars()
    for block in blocks:
        await db.delete(block)
    entities = (await db.execute(select(MethodEntity).where(MethodEntity.paper_id == paper_id))).scalars()
    for entity in entities:
        await db.delete(entity)


@router.post("/{paper_id}/reparse", response_model=PaperStatusOut)
async def reparse_paper(paper_id: str, request: Request, background_tasks: BackgroundTasks, db: AsyncSession = Depends(get_db)):
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    if paper.source_type == "pdf_upload" and not resolve_paper_pdf(paper.pdf_path, paper.id):
        raise HTTPException(404, "未找到原始 PDF，请先恢复源文件；现有解析内容已保留。")
    # A stale task may still be writing blocks; stop it before clearing, or
    # the deletion below races with fresh writes.
    jobs = _job_center(request)
    if jobs is not None:
        await jobs.cancel_for_paper(paper_id)
    await _clear_paper_analysis(db, paper_id)
    cached_output = resolve_storage_path(paper.mineru_output_dir, "mineru_output")
    cached_content = mineru.find_content_list(cached_output) if cached_output else ""
    paper.status = "parsed" if cached_content else "uploaded"
    paper.error_message = ""
    paper.error_code = None
    await db.commit()

    _launch(request, background_tasks, "mineru", paper.id, _process_paper, paper.id)
    return PaperStatusOut(id=paper.id, status=paper.status, error_message="", error_code="")


@router.post("/{paper_id}/resummarize", response_model=PaperStatusOut)
async def resummarize_paper(paper_id: str, request: Request, background_tasks: BackgroundTasks, db: AsyncSession = Depends(get_db)):
    """Retry only the whole-paper Reduce stage using completed Map data."""
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    jobs = _job_center(request)
    if jobs is not None:
        await jobs.cancel_for_paper(paper_id)
    block_count = len(list((await db.execute(select(Block.id).where(Block.paper_id == paper_id))).scalars().all()))
    if not block_count:
        raise HTTPException(409, "论文没有可复用的段落分析，请使用重新解析")
    paper.status = "reducing"
    paper.error_message = ""
    await db.commit()
    _launch(request, background_tasks, "reduce", paper.id, _resume_reduce_paper, paper.id)
    return PaperStatusOut(id=paper.id, status="reducing", error_message="", error_code="")


@router.post("/{paper_id}/retranslate", response_model=PaperStatusOut)
async def retranslate_paper(paper_id: str, request: Request, background_tasks: BackgroundTasks, db: AsyncSession = Depends(get_db)):
    """Re-run Map + Reduce for this paper while reusing its parsed blocks.

    This maintenance action is intentionally narrower than ``reparse``: the
    original MinerU structure and source PDF stay intact, while missing
    paragraph translations, one-liners, and Chinese logic-chain roles are
    regenerated for the current paper only.
    """
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    if paper.status not in {"ready", "error"}:
        raise HTTPException(409, "论文仍在处理中，请等待当前任务完成")
    jobs = _job_center(request)
    if jobs is not None:
        await jobs.cancel_for_paper(paper_id)
    block_count = len(list((await db.execute(select(Block.id).where(Block.paper_id == paper_id))).scalars().all()))
    if not block_count:
        raise HTTPException(409, "论文还没有可复用的解析段落，请使用重新解析")
    paper.status = "analyzing"
    paper.error_message = ""
    await db.commit()
    _launch(request, background_tasks, "map", paper.id, _retranslate_paper, paper.id)
    return PaperStatusOut(id=paper.id, status="analyzing", error_message="", error_code="")


@router.delete("/{paper_id}")
async def delete_paper(paper_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")
    # Cancel first: after this returns no background task can write the rows
    # or files that are about to disappear (T1.3).
    jobs = _job_center(request)
    if jobs is not None:
        await jobs.cancel_for_paper(paper_id)
    blocks = list((await db.execute(select(Block).where(Block.paper_id == paper_id))).scalars())
    entities = list((await db.execute(select(MethodEntity).where(MethodEntity.paper_id == paper_id))).scalars())
    # Stage files in the recycle bin; on failure nothing is deleted and the
    # caller keeps a fully intact paper.
    move_paper_to_trash(paper, blocks, entities)
    await _clear_paper_analysis(db, paper_id)
    await db.delete(paper)
    await db.commit()
    return {"ok": True}


# ── Background Processing Pipeline ────────────────────────

async def _process_paper(paper_id: str):
    """Full processing pipeline: parse → normalize → map → reduce."""
    from ..core.database import async_session

    async with async_session() as db:
        paper = await db.get(Paper, paper_id)
        if not paper:
            return

        # Load settings for API keys
        settings_row = await db.get(AppSettingsModel, "singleton")
        app_settings = settings_row.data if settings_row else {}

        # Get MinerU config
        mineru_cfg = app_settings.get("mineru", {})
        mineru_mode = mineru_cfg.get("mode", "cloud")
        mineru_base = mineru_cfg.get("base_url", settings.mineru_base_url)
        mineru_local_url = mineru_cfg.get("local_url", "http://127.0.0.1:7860")
        mineru_key = mineru_cfg.get("api_key", "") or settings.mineru_api_key
        if mineru_key:
            mineru_key = decrypt_or_empty(mineru_key)
        mineru_opts = mineru_cfg.get("default_options", {})

        # Get LLM config for analysis
        llm_map = resolve_llm(app_settings, LlmRole.TRANSLATION_AND_EXTRACTION)
        # An empty assignment value must not shadow the translation profile.
        # This is common for older settings records created before the
        # separate Reduce profile was introduced; the role chain handles it.
        llm_reduce = resolve_llm(app_settings, LlmRole.LOGIC_CHAIN_AND_SUMMARY)

        output_dir = str(settings.storage_root / "mineru_output" / paper_id)
        paper.mineru_output_dir = storage_reference(Path(output_dir))

        try:
            # Cancellation checkpoint: stage boundaries must observe a pending
            # cancel before touching MinerU/LLM or writing rows (T1.1).
            await asyncio.sleep(0)
            if mineru_mode != "local" and not mineru_key:
                raise PipelineError("未配置可用的 MinerU Token，请先在设置页保存并测试连接", ErrorCode.MINERU_NOT_CONFIGURED)
            if not llm_map.is_configured or not llm_reduce.is_configured:
                raise PipelineError("未配置可用的模型 API，请先在设置页保存并测试连接", ErrorCode.LLM_NOT_CONFIGURED)
            # Step 1: Parse with MinerU, or reuse a completed parse when only
            # downstream AI analysis failed.
            cached_content = mineru.find_content_list(output_dir) if paper.status == "parsed" else ""
            if cached_content:
                blocks_data = mineru.parse_content_list(cached_content)
            else:
                paper.status = "parsing"
                await db.commit()

                pdf_url = paper.source_url if paper.source_type == "url_pdf" else None
                pdf_path = resolve_paper_pdf(paper.pdf_path, paper.id) if paper.source_type == "pdf_upload" else None
                file_path = str(pdf_path) if pdf_path else None
                if paper.source_type == "pdf_upload" and not file_path:
                    raise PipelineError("未找到原始 PDF，请检查源文件是否已一同迁移。", ErrorCode.PDF_MISSING)

                if mineru_mode == "local":
                    if not file_path:
                        raise PipelineError("本地 MinerU 模式仅支持直接上传的 PDF 文件", ErrorCode.PDF_MISSING)
                    blocks_data, _ = await mineru.run_local_pipeline(
                        file_path=file_path,
                        base_url=mineru_local_url,
                        options=mineru_opts,
                        output_dir=output_dir,
                    )
                else:
                    blocks_data, _ = await mineru.run_full_pipeline(
                        file_path=file_path,
                        pdf_url=pdf_url,
                        base_url=mineru_base,
                        api_key=mineru_key,
                        options=mineru_opts,
                        output_dir=output_dir,
                    )

            if not blocks_data:
                raise PipelineError("MinerU 解析结果不包含可读取的论文内容", ErrorCode.PARSE_EMPTY)

            paper.status = "parsed"
            await db.commit()

            # Step 2: Normalize → create Block rows
            await asyncio.sleep(0)
            paper.status = "normalizing"
            await db.commit()

            title_abstract = f"标题：{paper.title}\n摘要：{paper.tldr}"
            block_models = []
            for bd in blocks_data:
                block = Block(
                    id=f"b{paper_id[:6]}-{bd['order'] + 1:04d}",
                    paper_id=paper_id,
                    order=bd["order"],
                    kind=bd.get("kind", "paragraph"),
                    page_idx=bd.get("page_idx"),
                    bbox=bd.get("bbox"),
                    section_title=bd.get("section_title", ""),
                    text_original=bd.get("text_original", ""),
                    caption_original=bd.get("caption_original", ""),
                    image_path=bd.get("image_path", ""),
                    table_html=bd.get("table_html", ""),
                    latex=bd.get("latex", ""),
                )
                db.add(block)
                block_models.append(block)
            await db.flush()

            # Step 3: Map phase
            await asyncio.sleep(0)
            paper.status = "analyzing"
            await db.commit()

            blocks_for_map = [
                {
                    "id": b.id,
                    "kind": b.kind,
                    "text_original": b.text_original or "",
                    "caption_original": b.caption_original or "",
                    "latex": b.latex or "",
                    "section_title": b.section_title or "",
                }
                for b in block_models
            ]
            map_raw: list[dict] = []
            map_results = await analysis.run_map_phase(
                llm_map,
                blocks_for_map,
                title_abstract,
                strict=True,
                raw_log=map_raw,
            )
            # Raw sidecar (T2.1): keep every provider response so cleaning /
            # derivation rules can be replayed without paying for the LLM again.
            write_analysis_raw(paper_id, "map_raw.json", {
                "model": llm_map.model, "created_at": _now(), "batches": map_raw,
            })

            # Apply map results
            result_by_id = {
                r.get("block_id"): r for r in map_results
                if isinstance(r, dict) and isinstance(r.get("block_id"), str)
            }
            all_entities_raw = []
            for b in block_models:
                r = result_by_id.get(b.id, {})
                translation = r.get("translation", "")
                if b.kind in ("figure", "table"):
                    b.caption_zh = translation
                else:
                    b.text_zh = translation
                b.one_liner = r.get("one_liner", "")
                b.keywords = r.get("keywords", [])
                for ent in r.get("entities", []):
                    if isinstance(ent, dict) and isinstance(ent.get("name"), str) and ent.get("name").strip():
                        all_entities_raw.append({**ent, "block_id": b.id})

            await db.flush()

            # Extract and deduplicate entities
            entity_map = {}  # canonical_key -> {name, category, block_ids}
            for ent in all_entities_raw:
                key = _canonical_key(ent["name"])
                if key not in entity_map:
                    entity_map[key] = {
                        "name": ent["name"],
                        "category": ent.get("category", "OTHER"),
                        "block_ids": [],
                    }
                if ent["block_id"] not in entity_map[key]["block_ids"]:
                    entity_map[key]["block_ids"].append(ent["block_id"])

            entity_models = []
            for key, edata in entity_map.items():
                entity = MethodEntity(
                    paper_id=paper_id,
                    canonical_key=key,
                    name=edata["name"],
                    category=edata["category"],
                    block_refs=edata["block_ids"],
                )
                db.add(entity)
                entity_models.append(entity)
            await db.flush()

            # Link blocks to entities explicitly. Accessing ``b.entities``
            # after an async flush can trigger an implicit lazy-load outside
            # SQLAlchemy's greenlet bridge (MissingGreenlet).
            entity_by_key = {entity.canonical_key: entity for entity in entity_models}
            association_rows = []
            for b in block_models:
                block_entity_keys = set()
                for ent in all_entities_raw:
                    if ent["block_id"] == b.id:
                        block_entity_keys.add(_canonical_key(ent["name"]))
                for key in block_entity_keys:
                    entity = entity_by_key.get(key)
                    if entity:
                        association_rows.append({"block_id": b.id, "entity_id": entity.id})
            if association_rows:
                await db.execute(insert(block_entity_table), association_rows)

            # Step 4: Reduce phase
            reduce_raw: list[dict] = []
            await _run_reduce_stage(db, paper, block_models, entity_models, llm_reduce, title_abstract, raw_log=reduce_raw)

        except Exception as e:
            set_paper_error(paper, e)
            await db.commit()


async def _run_reduce_stage(db, paper: Paper, block_models: list[Block], entity_models: list[MethodEntity], llm_reduce: LLMClient, title_abstract: str, raw_log: list[dict] | None = None):
    """Create and persist the whole-paper narrative from existing Map data."""
    await asyncio.sleep(0)
    paper.status = "reducing"
    await db.commit()

    one_liners_for_reduce = [
        {"block_id": b.id, "kind": b.kind, "one_liner": b.one_liner or "", "section_guess": b.section_title or ""}
        for b in block_models
    ]
    entities_for_reduce = [
        {"name": e.name, "category": e.category, "block_refs": e.block_refs}
        for e in entity_models
    ]
    reduce_raw: list[dict] = raw_log if raw_log is not None else []
    reduce_result = await analysis.run_reduce_phase(
        llm_reduce, title_abstract, one_liners_for_reduce, entities_for_reduce, raw_log=reduce_raw
    )
    if raw_log is not None:
        write_analysis_raw(paper.id, "reduce_raw.json", {
            "model": llm_reduce.model, "created_at": _now(), "attempts": reduce_raw,
        })

    paper.narrative_summary = reduce_result["narrative_summary"].strip()
    contributions = reduce_result.get("contributions", [])
    tags = reduce_result.get("domain_tags", [])
    paper.contributions = [str(item) for item in contributions if isinstance(item, (str, int, float))] if isinstance(contributions, list) else []
    paper.domain_tags = [str(item) for item in tags if isinstance(item, (str, int, float))] if isinstance(tags, list) else []
    paper.difficulty_estimate = str(reduce_result.get("difficulty_estimate", ""))
    if not paper.tldr:
        paper.tldr = paper.narrative_summary[:200]

    block_by_id = {block.id: block for block in block_models}
    for lc_item in reduce_result.get("logic_chain", []):
        if not isinstance(lc_item, dict):
            continue
        block = block_by_id.get(lc_item.get("block_id"))
        if block:
            block.role_in_narrative = str(lc_item.get("role_in_narrative", ""))

    for block in block_models[:5]:
        if block.kind == "section_heading" and block.text_original and not paper.title:
            paper.title = block.text_original
            break

    paper.status = "ready"
    paper.error_message = ""
    paper.error_code = None
    await db.commit()


async def _retranslate_paper(paper_id: str):
    """Retry the text-analysis stages without reparsing the source PDF."""
    from ..core.database import async_session

    async with async_session() as db:
        paper = await db.get(Paper, paper_id)
        if not paper:
            return

        settings_row = await db.get(AppSettingsModel, "singleton")
        app_settings = settings_row.data if settings_row else {}
        llm_map = resolve_llm(app_settings, LlmRole.TRANSLATION_AND_EXTRACTION)
        # Do not let an explicitly stored empty Reduce id fall through to an
        # unconfigured global client when the Map profile is valid.
        llm_reduce = resolve_llm(app_settings, LlmRole.LOGIC_CHAIN_AND_SUMMARY)
        blocks = list(
            (
                await db.execute(
                    select(Block).where(Block.paper_id == paper_id).order_by(Block.order)
                )
            ).scalars().all()
        )
        entities = list(
            (
                await db.execute(
                    select(MethodEntity).where(MethodEntity.paper_id == paper_id)
                )
            ).scalars().all()
        )

        try:
            await asyncio.sleep(0)
            if not blocks:
                raise PipelineError("论文还没有可复用的解析段落，请使用重新解析", ErrorCode.PARSE_EMPTY)
            if not llm_map.is_configured or not llm_reduce.is_configured:
                raise PipelineError("未配置可用的模型 API，请先在设置页保存并测试连接", ErrorCode.LLM_NOT_CONFIGURED)

            title_abstract = f"标题：{paper.title}\n摘要：{paper.tldr}"
            blocks_for_map = [
                {
                    "id": block.id,
                    "kind": block.kind,
                    "text_original": block.text_original or "",
                    "caption_original": block.caption_original or "",
                    "latex": block.latex or "",
                    "section_title": block.section_title or "",
                }
                for block in blocks
            ]
            map_raw: list[dict] = []
            map_results = await analysis.run_map_phase(
                llm_map,
                blocks_for_map,
                title_abstract,
                strict=True,
                raw_log=map_raw,
            )
            write_analysis_raw(paper_id, "map_raw.json", {
                "model": llm_map.model, "created_at": _now(), "batches": map_raw,
            })
            result_by_id = {
                result.get("block_id"): result
                for result in map_results
                if isinstance(result, dict) and isinstance(result.get("block_id"), str)
            }

            # Only replace a field when a fresh, non-empty value was returned;
            # a caption-less figure/table or equation should keep its existing
            # data instead of being blanked during a retry.
            for block in blocks:
                result = result_by_id.get(block.id, {})
                translation = result.get("translation", "")
                if isinstance(translation, str) and translation.strip():
                    if block.kind in ("figure", "table"):
                        block.caption_zh = translation.strip()
                    elif block.kind != "equation":
                        block.text_zh = translation.strip()
                one_liner = result.get("one_liner", "")
                if isinstance(one_liner, str) and one_liner.strip():
                    block.one_liner = one_liner.strip()
                keywords = result.get("keywords", [])
                if isinstance(keywords, list):
                    block.keywords = [
                        str(value) for value in keywords
                        if isinstance(value, (str, int, float))
                    ][:3]

            await db.flush()
            reduce_raw: list[dict] = []
            await _run_reduce_stage(db, paper, blocks, entities, llm_reduce, title_abstract, raw_log=reduce_raw)
        except Exception as exc:
            set_paper_error(paper, exc)
            await db.commit()


async def _resume_reduce_paper(paper_id: str):
    """Maintenance entry point: rerun Reduce without deleting completed Map data."""
    from ..core.database import async_session
    async with async_session() as db:
        paper = await db.get(Paper, paper_id)
        if not paper:
            raise ValueError("Paper not found")
        settings_row = await db.get(AppSettingsModel, "singleton")
        app_settings = settings_row.data if settings_row else {}
        llm_reduce = resolve_llm(app_settings, LlmRole.LOGIC_CHAIN_AND_SUMMARY)
        blocks = list((await db.execute(select(Block).where(Block.paper_id == paper_id).order_by(Block.order))).scalars().all())
        entities = list((await db.execute(select(MethodEntity).where(MethodEntity.paper_id == paper_id))).scalars().all())
        if not blocks:
            raise ValueError("Paper has no Map results")
        title_abstract = f"标题：{paper.title}\n摘要：{paper.tldr}"
        try:
            await asyncio.sleep(0)
            await _run_reduce_stage(db, paper, blocks, entities, llm_reduce, title_abstract)
        except Exception as exc:
            set_paper_error(paper, exc)
            await db.commit()
            raise


def _canonical_key(name: str) -> str:
    """Normalize entity name for deduplication."""
    import re
    key = name.lower().strip()
    key = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "_", key)
    return key.strip("_")
