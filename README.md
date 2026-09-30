<div align="center">

# Paperico

**A local-first, bring-your-own-key workbench for deep-reading research papers.**

Upload a PDF, let MinerU turn it into structured blocks, and read it side-by-side with an
AI-built logic-chain outline, sentence-level bilingual translation, method cards — and a
chat that cites the exact block it answers from.

[![CI](https://github.com/juliusloon/paperico/actions/workflows/ci.yml/badge.svg)](https://github.com/juliusloon/paperico/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/badge/release-v0.1.0-orange)](CHANGELOG.md)

English · [简体中文](README.zh-CN.md)

</div>

---

## Why Paperico

Deep-reading a paper is not the same as skimming a summary. Paperico is built around the
loop **read → understand the structure → ask → take notes**, with one hard rule: every AI
output must be traceable back to a specific location in the paper. Summaries, method cards
and chat citations all link to source blocks — the model is not allowed to speak about the
paper without a receipt.

Everything runs on your machine: PDFs, the SQLite database, extracted figures, and your
API keys (stored encrypted with Fernet). Paperico never proxies your documents through a
third-party service of its own — parsing and model calls go directly from your backend to
the providers **you** configure (BYOK).

## Features

- **Structured parsing** — PDFs are parsed by
  [MinerU](https://github.com/opendatalab/MinerU) (cloud `mineru.net` or a self-hosted
  endpoint) into typed blocks: paragraphs, headings, figures, tables, equations.
- **Logic-chain outline** — an LLM-generated chain of "what role does this section play in
  the argument" entries, synced with your scroll position.
- **Sentence-level bilingual reading** — side-by-side original/translation with per-block
  retranslation; target language configurable.
- **Method cards & entities** — methods used in the paper extracted into a browsable
  index, across all papers in your library.
- **Evidence-grounded chat** — streaming SSE chat where every answer cites the blocks it
  is based on; click a citation to jump and flash-highlight the source. Attach extra
  context: text selections, method cards, figures.
- **Notes mode** — multi-select blocks, generate structured notes, export Markdown.
- **Library management** — projects, status filters, dedup on import, batch operations,
  soft-delete with restore.
- **Native macOS client** — SwiftUI + PDFKit, zero third-party dependencies, talking to
  the same local backend as any API client would.
- **PDF mode** — original PDF rendering (PDFKit) alongside the structured view, with
  progress synced in both directions.

## Architecture

```text
┌──────────────────────┐
│  macOS app (SwiftUI) │      ← any HTTP client can talk to the API
└──────────┬───────────┘
           │  REST + SSE
           ▼
   ┌───────────────────┐   delegates    ┌───────────────────────┐
   │ FastAPI + SQLite, │ ─────────────▶ │ MinerU (cloud or      │
   │ local storage of  │                │ self-hosted)          │
   │ PDFs & blocks     │ ─────────────▶ │ any OpenAI-compatible │
   └───────────────────┘                │ LLM endpoint          │
                                        └───────────────────────┘
```

| Directory | What it is |
|---|---|
| [`backend/`](backend) | FastAPI server: jobs, storage, encrypted settings, REST + SSE API |
| [`macos/`](macos) | Native macOS client: SwiftUI + PDFKit (single Xcode target) |
| [`docs/`](docs) | Engineering notes: bbox coordinates, storage migration, chemistry parsing spike |
| [`design/`](design) | Logo concepts and icon asset breakdowns |

## Quickstart

Prerequisites: **Python 3.11+**.

```bash
git clone https://github.com/juliusloon/paperico.git
cd paperico
./start.sh
```

`start.sh` creates the Python virtualenv and installs dependencies on first run, then
starts the backend:

- Backend API: http://127.0.0.1:8000 · interactive docs at http://127.0.0.1:8000/docs

Prefer manual setup? See [`backend/README.md`](backend/README.md).

### First run

1. Launch the macOS app (below), go to **Settings**, and fill in your keys:
   - **LLM**: any OpenAI-compatible endpoint (base URL + key + model). This powers
     translation, outlines, method cards and chat.
   - **MinerU**: a `mineru.net` API key, or point the base URL at your self-hosted
     instance. This powers PDF parsing.
2. (Recommended, instead of the UI) copy [`backend/.env.example`](backend/.env.example)
   to `backend/.env` and set the values there — see the
   [configuration table](#configuration).
3. Upload a PDF on the home page and wait for parsing to finish.

> API keys entered in Settings are encrypted with Fernet before being stored. The key file
> lives under the backend storage directory (mode 0600), or provide your own via
> `PAPERICO_ENCRYPTION_KEY`.

### Install the macOS app

Prebuilt DMGs are attached to each [GitHub Release](https://github.com/juliusloon/paperico/releases)
(or build one yourself: `cd macos && ./scripts/make_dmg.sh`). Open the DMG and drag
**Paperico** into *Applications*.

Releases are currently **unsigned**: on first launch macOS Gatekeeper will warn —
right-click the app → **Open** → **Open** to confirm. With a Developer ID you can produce
signed builds: `PAPERICO_SIGN_IDENTITY="Developer ID Application: …" ./scripts/make_dmg.sh`
(then notarize before distribution).

### Where is my data?

- **The app itself** is sandboxed and keeps preferences and per-paper reader state in its
  container (`~/Library/Containers/com.paperico.native/`), diagnostics logs under
  `~/Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico/logs/`.
- **Your papers, PDFs and extracted figures** belong to the backend, not the app:
  - `./start.sh` (repository mode, default) stores everything inside the repository
    folder (`backend/paperico.db` + `backend/app/storage/`);
  - `./start.sh --app-data` stores everything in
    `~/Library/Application Support/Paperico/` — the layout you want once the backend is
    part of your daily setup. Existing repository data is copied over on first use.
    The API keys you enter in Settings are stored encrypted (Fernet) in either mode.

### macOS app

The native client is a single SwiftUI target that talks to the same backend.

Prerequisites: macOS 14+, [Xcode 16+](https://developer.apple.com/xcode/).

```bash
open macos/Paperico.xcodeproj   # select the Paperico scheme → Run (⌘R)
```

On first launch, set the server address under **Settings → Server** (for example
`http://127.0.0.1:8000` for a backend on the same machine). Build instructions and the
API-contract check are described in [`macos/README.md`](macos/README.md).

## Configuration

All backend settings are optional environment variables prefixed with `PAPERICO_`
(loaded from `backend/.env`). See [`backend/.env.example`](backend/.env.example) for the
full list; the most common ones:

| Variable | Purpose | Default |
|---|---|---|
| `PAPERICO_LLM_BASE_URL` | OpenAI-compatible endpoint for translation/chat/notes | `https://api.openai.com/v1` |
| `PAPERICO_LLM_API_KEY` | API key for the LLM endpoint (or set it in Settings) | — |
| `PAPERICO_LLM_MODEL` | Model name | `gpt-4o-mini` |
| `PAPERICO_MINERU_BASE_URL` | MinerU API base (cloud or self-hosted) | `https://mineru.net/api/v4` |
| `PAPERICO_MINERU_API_KEY` | MinerU key (or set it in Settings) | — |
| `PAPERICO_ENCRYPTION_KEY` | Fernet key for encrypting stored credentials | generated locally |
| `PAPERICO_STORAGE_ROOT` | Where PDFs/figures/extracts live | `backend/app/storage` |
| `PAPERICO_JOB_KIND_LIMITS` | Per-kind concurrency caps, e.g. `{"mineru": 4}` | — |

Keys configured via the Settings page are stored encrypted in the database; environment
variables are useful for headless setups.

## Roadmap

- [x] v0.1.0 — initial open-source release: parsing, bilingual reading, evidence-grounded
      chat, notes, library, backend + macOS client
- [ ] Batch import (Zotero / arXiv export files)
- [ ] Multi-paper chat across a project
- [ ] Optional multi-user mode with authentication

See [`CHANGELOG.md`](CHANGELOG.md) for what shipped in each release.

## Contributing

Contributions are welcome — bug reports, docs, and code. Start with
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the development setup, the backend↔client
API-contract rule, and how to run the test suites.

## Security

Found a security issue? Please report it privately — see
[`SECURITY.md`](SECURITY.md). Please do not open a public issue for vulnerabilities.

## License

[MIT](LICENSE) © 2026 juliusloon. MinerU is used via its public API and remains the
property of its respective authors.
