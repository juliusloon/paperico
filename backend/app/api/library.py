"""Cross-paper method/terminology index."""

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from ..core.database import get_db
from ..core.models import MethodEntity, Paper, ProjectGroup
from ..core.schemas import MethodIndexItem

router = APIRouter()


@router.get("/methods", response_model=list[MethodIndexItem])
async def get_method_index(
    project_id: str | None = Query(None),
    category: str | None = Query(None),
    q: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    """Get cross-paper method/terminology index."""
    query = select(MethodEntity)
    if category:
        query = query.where(MethodEntity.category == category)
    if q:
        query = query.where(MethodEntity.name.contains(q))
    result = await db.execute(query)
    entities = result.scalars().all()

    # Group by canonical_key
    grouped: dict[str, list] = {}
    for e in entities:
        key = e.canonical_key
        if key not in grouped:
            grouped[key] = []
        grouped[key].append(e)

    # Build index items
    items = []
    for key, ents in grouped.items():
        paper_ids = list(set(e.paper_id for e in ents))
        if project_id:
            # Filter to papers in project
            papers_result = await db.execute(
                select(Paper).where(Paper.id.in_(paper_ids), Paper.project_id == project_id)
            )
            papers = papers_result.scalars().all()
            if not papers:
                continue
            paper_ids = [p.id for p in papers]

        paper_details = []
        for pid in paper_ids:
            paper = await db.get(Paper, pid)
            if paper:
                block_ids = []
                for e in ents:
                    if e.paper_id == pid:
                        block_ids.extend(e.block_refs or [])
                paper_details.append({
                    "paper_id": pid,
                    "title": paper.title,
                    "block_ids": list(set(block_ids)),
                })

        if paper_details:
            first = ents[0]
            items.append(MethodIndexItem(
                canonical_key=key,
                name=first.name,
                category=first.category,
                definition_zh=first.definition_zh or "",
                papers=paper_details,
            ))

    return items
