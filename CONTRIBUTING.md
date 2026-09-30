# Contributing to Paperico

Thanks for your interest in improving Paperico! This document covers the development
setup, the project's conventions, and the few rules that keep the macOS client and the
backend from drifting apart.

## Project layout

```text
backend/    FastAPI server (Python 3.11+, SQLAlchemy async + SQLite)
macos/      Native macOS client (SwiftUI + PDFKit, single Xcode target)
docs/       Engineering notes
design/     Logo concepts and icon assets
```

## Development setup

### Backend

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

pytest                 # run the test suite
ruff check .           # lint
uvicorn app.main:app --reload   # dev server on :8000
```

If you use [uv](https://docs.astral.sh/uv/): `uv pip install --python .venv/bin/python -e ".[dev]"`.

Configuration is read from `backend/.env` (see
[`backend/.env.example`](backend/.env.example)) or `PAPERICO_*` environment variables.

### macOS client

Prerequisites: macOS 14+, Xcode 16+ (the project uses file-system synchronized groups).

```bash
cd macos
open Paperico.xcodeproj   # Paperico scheme → Run (⌘R)
xcodebuild -project Paperico.xcodeproj -scheme Paperico \
  -destination 'platform=macOS' build     # CLI build
```

Swift files are picked up automatically (synchronized groups) — there is no need to
regenerate the project when adding files. After a backend API schema change, run the
contract check (next section).

## The API-contract rule

`macos/Paperico/Models/Models.swift` mirrors the backend Pydantic schemas field-for-field.
Whenever you change an API response schema in `backend/`, you **must**:

1. update `backend/tests/openapi_snapshot.json` (the snapshot test fails otherwise), and
2. run `macos/scripts/check_api_contract.py` (offline: against a dumped `openapi.json`,
   or online against a running backend) and update the Swift models + script snapshot
   until it prints `contract OK`.

This is enforced by the backend test suite; PRs that break it will not pass CI.

## Conventions

- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/) —
  `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, with an optional scope such as
  `feat(backend):` / `fix(macos):`.
- **Python**: formatted and linted with `ruff` (config in `backend/pyproject.toml`).
  New backend behaviour needs pytest coverage; migration scripts need a regression test.
- **Docs**: the repository language is English; the Chinese README
  ([`README.zh-CN.md`](README.zh-CN.md)) should be kept in sync with the English one.
- **Secrets never enter the repo**: no API keys, `.env` files, or local database/PDF
  storage. CI scans fail the build on obvious key patterns.

## Submitting changes

1. Fork / create a branch (`feat/my-change`).
2. Make the change with tests where applicable.
3. Run `pytest` (backend) and a macOS `xcodebuild` build if you touched `macos/`.
4. Update [`CHANGELOG.md`](CHANGELOG.md) under **Unreleased** for user-visible changes.
5. Open a pull request using the template; link any related issues.

## Reporting bugs

Open a [bug report](https://github.com/juliusloon/paperico/issues/new?template=bug_report.yml)
with your OS, client (macOS app / backend API), backend version and relevant logs. For
security issues, follow [`SECURITY.md`](SECURITY.md) instead.
