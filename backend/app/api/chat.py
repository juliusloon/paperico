"""Chat endpoints with SSE streaming."""

import json

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sse_starlette.sse import EventSourceResponse
from starlette.requests import Request

from ..core.config import settings
from ..core.database import get_db
from ..core.models import (
    AppSettingsModel,
    Block,
    ChatMessage,
    ChatSession,
    MethodEntity,
    Paper,
)
from ..core.schemas import ChatMessageCreate, ChatMessageOut, ChatSessionOut
from ..services.analysis import build_chat_system_prompt
from ..services.context import (
    FIGURE_SUMMARY_LIMIT,
    SELECTION_SNIPPET_LIMIT,
    build_paper_context,
    clip_text,
)
from ..services.profiles import LlmRole, resolve_llm

router = APIRouter()


@router.post("/{paper_id}/chat")
async def send_chat_message(
    paper_id: str,
    data: ChatMessageCreate,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    paper = await db.get(Paper, paper_id)
    if not paper:
        raise HTTPException(404, "Paper not found")

    # Get or create session
    if data.session_id:
        session = await db.get(ChatSession, data.session_id)
        if not session:
            session = ChatSession(paper_id=paper_id, title=data.content[:50])
            db.add(session)
            await db.flush()
    else:
        session = ChatSession(paper_id=paper_id, title=data.content[:50])
        db.add(session)
        await db.flush()

    # Save user message
    user_msg = ChatMessage(
        session_id=session.id,
        role="user",
        content=data.content,
        attached_context=[c.model_dump() for c in data.attached_context] if data.attached_context else None,
    )
    db.add(user_msg)
    await db.commit()

    # Build context. The layered builder (T2.2) discards whole semantic lines
    # under a budget and always keeps section headings; the legacy switch
    # restores the old hard slices for one observation cycle if needed.
    blocks_result = await db.execute(select(Block).where(Block.paper_id == paper_id))
    blocks = blocks_result.scalars().all()
    entities_result = await db.execute(select(MethodEntity).where(MethodEntity.paper_id == paper_id))
    entities = entities_result.scalars().all()

    logic_chain = "\n".join(
        f"[{b.id}] {b.section_title or ''}-{b.role_in_narrative or ''}: {b.one_liner or ''}"
        for b in blocks if b.one_liner
    )
    method_index = "\n".join(
        f"{e.name}({e.category}) → 出现于 {','.join(e.block_refs or [])}"
        for e in entities
    )
    if settings.chat_legacy_truncation:
        paper_context = (
            "【全文逻辑链（压缩版，按原文顺序）】\n" + logic_chain[:3000]
            + "\n\n【已识别方法/实体索引】\n" + method_index[:2000]
        )
    else:
        paper_context = build_paper_context(blocks, entities)

    # Load settings
    settings_row = await db.get(AppSettingsModel, "singleton")
    app_settings = settings_row.data if settings_row else {}
    llm = resolve_llm(app_settings, LlmRole.CHAT)
    if not llm.is_configured:
        raise HTTPException(409, "未配置可用的对话模型，请先在设置页保存并测试模型连接")

    system_prompt = build_chat_system_prompt(
        title=paper.title or "",
        title_zh=paper.title_zh or "",
        domain_tags=paper.domain_tags or [],
        tldr=paper.tldr or "",
        paper_context=paper_context,
    )

    # Build attached context
    attached_text = ""
    for ctx in data.attached_context:
        if ctx.type == "text_selection":
            if ctx.ref_block_id:
                block = await db.get(Block, ctx.ref_block_id)
                if block:
                    attached_text += f"\n[引用段落 {block.id}]: {clip_text(block.text_original, SELECTION_SNIPPET_LIMIT)}"
            elif ctx.snippet:
                attached_text += f"\n[PDF 选中文本]: {clip_text(ctx.snippet, SELECTION_SNIPPET_LIMIT)}"
        elif ctx.type == "method_card" and ctx.ref_entity_id:
            entity = await db.get(MethodEntity, ctx.ref_entity_id)
            if entity:
                attached_text += f"\n[方法实体 {entity.name}]: 定义 {entity.definition_zh}，出现于 {','.join(entity.block_refs or [])}"
        elif ctx.type == "figure" and ctx.ref_block_id:
            block = await db.get(Block, ctx.ref_block_id)
            if block:
                summary = clip_text(
                    "；".join(filter(None, [block.caption_original, ", ".join(block.core_takeaways or [])])),
                    FIGURE_SUMMARY_LIMIT,
                )
                attached_text += f"\n[图表 {block.id}]: {summary}"

    if attached_text:
        system_prompt += f"\n\n【本轮用户手动附带的上下文】\n{attached_text}"

    # Build message history
    history_result = await db.execute(
        select(ChatMessage)
        .where(ChatMessage.session_id == session.id)
        .order_by(ChatMessage.created_at)
    )
    messages = [{"role": "system", "content": system_prompt}]
    for msg in history_result.scalars().all():
        messages.append({"role": msg.role, "content": msg.content})

    # SSE streaming response
    async def event_generator():
        full_content = ""
        try:
            async for chunk in llm.chat_stream(messages=messages, temperature=0.3, max_tokens=4096):
                if await request.is_disconnected():
                    break
                full_content += chunk
                yield {"event": "chunk", "data": json.dumps({"content": chunk})}
        except Exception as e:
            yield {"event": "error", "data": json.dumps({"error": str(e)})}

        # Save assistant message
        cited_ids = _extract_block_refs(full_content, {b.id for b in blocks})
        assistant_msg = ChatMessage(
            session_id=session.id,
            role="assistant",
            content=full_content,
            cited_block_ids=cited_ids,
        )
        async with async_session() as save_db:
            save_db.add(assistant_msg)
            await save_db.commit()

        yield {"event": "done", "data": json.dumps({
            "message_id": assistant_msg.id,
            "session_id": session.id,
            "cited_block_ids": cited_ids,
        })}

    from ..core.database import async_session
    return EventSourceResponse(event_generator())


@router.get("/{paper_id}/chat/{session_id}", response_model=ChatSessionOut)
async def get_chat_session(paper_id: str, session_id: str, db: AsyncSession = Depends(get_db)):
    session = await db.get(ChatSession, session_id)
    if not session:
        raise HTTPException(404, "Session not found")
    return ChatSessionOut(
        id=session.id, paper_id=session.paper_id,
        title=session.title or "", created_at=session.created_at,
        messages=[
            ChatMessageOut(
                id=m.id, session_id=m.session_id, role=m.role,
                content=m.content, attached_context=m.attached_context,
                cited_block_ids=m.cited_block_ids, created_at=m.created_at,
            )
            for m in session.messages
        ],
    )


@router.get("/{paper_id}/chat", response_model=list[ChatSessionOut])
async def list_chat_sessions(paper_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ChatSession).where(ChatSession.paper_id == paper_id).order_by(ChatSession.created_at.desc())
    )
    sessions = result.scalars().all()
    return [
        ChatSessionOut(
            id=s.id, paper_id=s.paper_id, title=s.title or "",
            created_at=s.created_at, messages=[],
        )
        for s in sessions
    ]


def _extract_block_refs(text: str, valid_ids: set[str]) -> list[str]:
    """Extract [bxxxx] references from assistant response."""
    import re
    refs = re.findall(r"\[([^\[\]]+)\]", text)
    return list(dict.fromkeys(ref for ref in refs if ref in valid_ids))
