"""Note synthesis and management endpoints."""

import json
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from ..core.database import get_db
from ..core.models import Paper, Block, MethodEntity, ChatMessage, Note, AppSettingsModel
from ..core.schemas import NoteCreate, NoteOut
from ..services.analysis import synthesize_note
from ..services.profiles import LlmRole, resolve_llm

router = APIRouter()


@router.post("/{paper_id}/notes/synthesize", response_model=NoteOut)
async def generate_note(
    paper_id: str,
    data: NoteCreate,
    db: AsyncSession = Depends(get_db),
):
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")

    # Gather selected messages
    messages = []
    for mid in data.message_ids:
        msg = await db.get(ChatMessage, mid)
        if msg:
            messages.append({"role": msg.role, "content": msg.content})

    if not messages:
        raise HTTPException(400, "No valid messages selected")

    # Gather structured context
    blocks_result = await db.execute(select(Block).where(Block.paper_id == paper_id).order_by(Block.order))
    blocks = blocks_result.scalars().all()
    entities_result = await db.execute(select(MethodEntity).where(MethodEntity.paper_id == paper_id))
    entities = entities_result.scalars().all()

    logic_chain = [
        {"block_id": b.id, "role": b.role_in_narrative or "", "one_liner": b.one_liner or ""}
        for b in blocks if b.one_liner
    ]
    method_index = [
        {"name": e.name, "category": e.category, "block_refs": e.block_refs or []}
        for e in entities
    ]

    paper_meta = {
        "title": paper.title,
        "title_zh": paper.title_zh or "",
        "authors": paper.authors or [],
        "year": paper.year,
        "venue": paper.venue or "",
        "domain_tags": paper.domain_tags or [],
    }

    # Get LLM for synthesis
    settings_row = await db.get(AppSettingsModel, "singleton")
    app_settings = settings_row.data if settings_row else {}
    llm = resolve_llm(app_settings, LlmRole.NOTE_SYNTHESIS)
    if not llm.is_configured:
        raise HTTPException(409, "未配置可用的笔记模型，请先在设置页完成模型配置")

    structured_context = {"logic_chain": logic_chain, "method_index": method_index}
    markdown = await synthesize_note(llm, paper_meta, structured_context, messages)

    # Add frontmatter if missing
    if not markdown.startswith("---"):
        from datetime import datetime, timezone
        tags = ["paper-note"] + (paper.domain_tags or [])
        frontmatter = f"""---
title: "{paper.title_zh or paper.title}"
title_original: "{paper.title}"
source: "{paper.source_url or paper.original_file_name}"
authors: {json.dumps(paper.authors or [])}
year: {paper.year or ''}
project: "{paper.project_id or ''}"
domain_tags: {json.dumps(paper.domain_tags or [])}
status: "已读"
created: "{datetime.now(timezone.utc).isoformat()}"
tags: {json.dumps(tags)}
---

"""
        markdown = frontmatter + markdown

    title = data.title or f"{paper.title_zh or paper.title} - 笔记"
    note = Note(
        paper_id=paper_id,
        title=title,
        markdown_content=markdown,
    )
    db.add(note)
    await db.commit()
    await db.refresh(note)

    return NoteOut(
        id=note.id, paper_id=note.paper_id, title=note.title,
        markdown_content=note.markdown_content,
        created_at=note.created_at, updated_at=note.updated_at,
    )


@router.get("/{paper_id}/notes", response_model=list[NoteOut])
async def list_notes(paper_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Note).where(Note.paper_id == paper_id).order_by(Note.created_at.desc())
    )
    return [
        NoteOut(
            id=n.id, paper_id=n.paper_id, title=n.title,
            markdown_content=n.markdown_content,
            created_at=n.created_at, updated_at=n.updated_at,
        )
        for n in result.scalars().all()
    ]
