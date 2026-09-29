"""Project group CRUD endpoints."""

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from sqlalchemy.orm import noload

from ..core.database import get_db
from ..core.models import ProjectGroup, Paper
from ..core.schemas import ProjectCreate, ProjectOut

router = APIRouter()


@router.post("", response_model=ProjectOut)
async def create_project(data: ProjectCreate, db: AsyncSession = Depends(get_db)):
    proj = ProjectGroup(name=data.name, description=data.description, color_tag=data.color_tag)
    db.add(proj)
    await db.commit()
    await db.refresh(proj)
    return ProjectOut(
        id=proj.id, name=proj.name, description=proj.description,
        color_tag=proj.color_tag, paper_count=0, created_at=proj.created_at,
    )


@router.get("", response_model=list[ProjectOut])
async def list_projects(db: AsyncSession = Depends(get_db)):
    # The sidebar only needs project metadata and counts. Avoid loading every
    # paper (and its parsed relationships) through the selectin relationship.
    result = await db.execute(select(ProjectGroup).options(noload(ProjectGroup.papers)))
    projects = result.scalars().all()
    out = []
    for p in projects:
        cnt = await db.execute(select(func.count()).where(Paper.project_id == p.id))
        count = cnt.scalar() or 0
        out.append(ProjectOut(
            id=p.id, name=p.name, description=p.description,
            color_tag=p.color_tag, paper_count=count, created_at=p.created_at,
        ))
    return out


@router.put("/{project_id}", response_model=ProjectOut)
async def update_project(project_id: str, data: ProjectCreate, db: AsyncSession = Depends(get_db)):
    proj = await db.get(ProjectGroup, project_id)
    if not proj:
        from fastapi import HTTPException
        raise HTTPException(404, "Project not found")
    proj.name = data.name
    proj.description = data.description
    proj.color_tag = data.color_tag
    await db.commit()
    cnt = await db.execute(select(func.count()).where(Paper.project_id == proj.id))
    count = cnt.scalar() or 0
    return ProjectOut(
        id=proj.id, name=proj.name, description=proj.description,
        color_tag=proj.color_tag, paper_count=count, created_at=proj.created_at,
    )


@router.delete("/{project_id}")
async def delete_project(project_id: str, db: AsyncSession = Depends(get_db)):
    proj = await db.get(ProjectGroup, project_id)
    if not proj:
        from fastapi import HTTPException
        raise HTTPException(404, "Project not found")
    # Unlink papers from this group before deleting (papers are preserved)
    result = await db.execute(select(Paper).where(Paper.project_id == project_id))
    for paper in result.scalars().all():
        paper.project_id = None
    await db.delete(proj)
    await db.commit()
    return {"ok": True}
