# Contributing to Paperico

The native macOS app is the primary product. The Python REST/SSE server is retained
as an independent compatibility component. See [docs/architecture.md](docs/architecture.md)
for the current ownership boundaries and [docs/releases/v0.2.0.md](docs/releases/v0.2.0.md)
for the native migration changes.

## Native development

Prerequisites: macOS 26+ and Xcode 26+. From the repository root:

```bash
./script/build_and_run.sh
./script/check.sh
./script/build_and_run.sh --verify
```

The Codex Run action calls the same build/run script. Swift files are automatically
included by the Xcode synchronized group; do not regenerate the project to add files.
`macos/Package.swift` tests selected core sources and is not a second GUI application.

Put app dependency wiring in `App/`, observable UI state in `Stores/`, persistence and
service logic in `Core/`, and view composition in `Pages/` or `Components/`. Keep files
named after their responsibility. Actor isolation alone does not make a read/modify/write
transaction safe if it suspends between reading and saving.

Regression tests for persistence, task lifecycle or service protocol behavior belong in
`macos/Tests/PapericoCoreTests/`. Use synthetic PDFs, ZIPs and temporary directories;
do not call paid APIs or rely on the developer's real library. Reversible visual-only
changes normally need a build and a focused UI check, rather than implementation-mirroring tests.

## Compatibility backend

The `backend/` directory is kept locally and is not part of the public repository;
this section applies only if you have a local copy.

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
pytest -q
ruff check .
uvicorn app.main:app --reload
```

Configuration uses `backend/.env` and `PAPERICO_*` variables; those settings do not
configure the native app. Run both tracks with `./script/check.sh --with-backend` after
installing the backend dev dependencies.

When changing a backend response schema, update `backend/tests/openapi_snapshot.json`
and run `macos/scripts/check_api_contract.py`. Retained Swift DTOs and the script's
snapshot must agree. This is a compatibility-data contract, not a native runtime dependency.

## Releases and documentation

- Update both root READMEs when changing setup, data ownership or system requirements.
- Record user-visible changes under Unreleased in CHANGELOG.md, then create a dated
  version entry and release note when preparing a release.
- Keep app target and project-bootstrap marketing/build versions consistent.
- Package with `macos/scripts/make_dmg.sh`; local ad-hoc signing is separate from
  Developer ID signing and notarization.
- Treat earlier backend/web engineering plans in `docs/` as historical context.

## Repository hygiene

Use Conventional Commit prefixes such as `feat(macos):` or `fix(backend):`. Never add
credentials, environment files, PDFs, personal databases, build output or screenshots
with paper contents. CI contains a credential-pattern scan.

Bug reports should identify the app or API component, version, OS, reproducible steps
and relevant diagnostics. Report security issues through [SECURITY.md](SECURITY.md).
