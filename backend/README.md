# Paperico Backend

FastAPI server: paper library, background job center, local storage, encrypted
settings, and the REST + SSE API consumed by the web and macOS clients.

## Stack

- FastAPI + Uvicorn (REST + SSE)
- SQLAlchemy 2 (async) + SQLite via aiosqlite
- Pydantic v2 + pydantic-settings (`PAPERICO_*` env vars, see
  [`.env.example`](.env.example))
- httpx for MinerU / LLM calls, cryptography (Fernet) for credential encryption

## Layout

```text
app/
├── api/         routers: projects, papers, chat, notes, library, settings
├── core/        config, database, models, schemas, storage, jobs, trash, crypto
├── services/    mineru (parsing), llm, analysis, context, profiles, reconcile
└── main.py      app entry; mounts /api routers and /api/files static storage
scripts/         maintenance & migration utilities
tests/           pytest suite incl. an OpenAPI snapshot contract test
```

## Run

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e .                 # add ".[dev]" for test/lint tools
uvicorn app.main:app --reload    # http://127.0.0.1:8000, docs at /docs
```

Or from the repository root: `./start.sh` (bootstraps venv + dependencies and starts
backend and web client together).

Configuration is read from `backend/.env` or `PAPERICO_*` environment variables —
all optional; see [`.env.example`](.env.example).

## Develop

```bash
pip install -e ".[dev]"
pytest            # full suite (65 tests, incl. OpenAPI snapshot)
ruff check .      # lint (config in pyproject.toml)
```

Notes for contributors:

- **API schema changes** must keep `tests/openapi_snapshot.json` updated (the snapshot
  test enforces it) and pass `ios/scripts/check_api_contract.py` — see the root
  [CONTRIBUTING.md](../CONTRIBUTING.md).
- Uploaded PDFs, extracted figures and sidecars live under
  `PAPERICO_STORAGE_ROOT` (default `app/storage/`, gitignored). The SQLite database is
  `backend/paperico.db` (gitignored).
- Soft-deleted papers go to a trash area and are purged after
  `PAPERICO_TRASH_RETENTION_DAYS` (default 7).

## Maintenance scripts

| Script | Purpose |
|---|---|
| `scripts/audit_storage.py` | Audit storage tree vs database references |
| `scripts/migrate_schema_v2.py` | One-off schema migration helper |
| `scripts/restore_from_trash.py` | Restore a soft-deleted batch |
| `scripts/mineru_chem_spike.py` | Chemistry-structure parsing spike |
