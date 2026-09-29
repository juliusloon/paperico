"""FastAPI application entry point."""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import logging

from .core.database import init_db, async_session
from .core.jobs import JobCenter
from .core.storage import migrate_storage_references
from .core.trash import purge_expired_batches
from .core.config import settings, ensure_dirs
from .services.reconcile import reconcile_interrupted_papers
from .api import projects, papers, chat, notes, settings_api, library


@asynccontextmanager
async def lifespan(app: FastAPI):
    ensure_dirs()
    await init_db()
    async with async_session() as db:
        report = await migrate_storage_references(db)
        logging.getLogger(__name__).info("Storage reference check: %s", report)
    app.state.jobs = JobCenter(settings.job_kind_limits)
    purged = purge_expired_batches()
    if purged:
        logging.getLogger(__name__).info("Expired trash batches purged: %s", purged)
    async with async_session() as db:
        await reconcile_interrupted_papers(db, app.state.jobs)
    yield
    await app.state.jobs.cancel_all()


app = FastAPI(title="Paperico", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve stored files (PDFs, images)
storage = settings.storage_root
app.mount("/api/files", StaticFiles(directory=str(storage), check_dir=False), name="files")

app.include_router(projects.router, prefix="/api/projects", tags=["projects"])
app.include_router(papers.router, prefix="/api/papers", tags=["papers"])
app.include_router(chat.router, prefix="/api/papers", tags=["chat"])
app.include_router(notes.router, prefix="/api/papers", tags=["notes"])
app.include_router(settings_api.router, prefix="/api/settings", tags=["settings"])
app.include_router(library.router, prefix="/api/library", tags=["library"])


@app.get("/api/health")
async def health():
    return {"status": "ok"}
