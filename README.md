<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Paperico — a local-first, bring-your-own-key native macOS paper reading workbench. Import a paper, read it bilingually, question it with evidence, and turn the discussion into notes. The Paperico app icon, a blue P over a gray O, sits on the right.">
</p>

<div align="center">

[![CI](https://github.com/juliusloon/paperico/actions/workflows/ci.yml/badge.svg)](https://github.com/juliusloon/paperico/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/badge/download-v1.0.0-0A84FF)](https://github.com/juliusloon/paperico/releases)

English · [简体中文](README.zh-CN.md)

</div>

## What is Paperico

Paperico is a native macOS app for deep-reading research papers. Import a PDF, let MinerU
recover its structure, then read original and translation side by side with a logic-chain
outline, method cards and the source PDF one click away. Ask questions with selections,
methods or figures attached; valid block citations jump straight back to their evidence.

Your library lives in your own sandbox, API keys stay in the macOS Keychain, and the app
connects directly to the services you configure. **Local-first, bring-your-own-key, no relay
server, no Python backend needed to run the app.**

## Why it's different

Ordinary PDF readers optimize *viewing a document*. Paperico restructures the paper into a
logic chain of typed blocks with stable ids — one coordinate system shared by the outline,
the translation, chat citations, method cards and annotations.

- **Structure, not pages.** MinerU recovers headings, paragraphs, figures, tables and
  equations with their positions; front matter, references and publisher boilerplate are
  separated out. You read a re-typeset bilingual surface — serif body, offline KaTeX —
  next to a logic-chain outline, and every jump lands on the exact block or PDF region.
- **One pass, whole paper.** A single streaming LLM request produces the block-aligned
  translation, per-paragraph takeaways and narrative roles, the paper-level TL;DR /
  contributions / difficulty estimate, and a method & entity index. Output is strictly
  validated, and an interrupted run recovers locally from the saved raw response — no
  second paid call.
- **Answers pinned to evidence.** Attach a selection, figure or method card to the
  question; replies cite block ids that jump straight back to their source paragraph or
  flash the region in the original PDF. Method entities merge across the whole library
  into persistent groups you curate — rename, regroup, delete — and every new paper is
  analyzed against your curated index, so one card lists every paper and paragraph where
  a method appears.
- **Local-first, BYOK, built to survive.** The pipeline checkpoints cloud tasks, continues
  queued jobs without re-uploading, reconciles jobs interrupted by a restart, dedups
  imports by content hash and keeps a restorable trash — while library files stay in the sandbox and API credentials are stored in Keychain.
  Parsing and AI requests send content directly to your configured services.
- **Your library speaks MCP.** An opt-in localhost server in Settings → MCP gives any
  Streamable-HTTP client — Claude Code, Cursor, VS Code — 10 read-only tools plus
  per-paper resources: metadata, bilingual blocks, figures, the method index and notes.
  The bearer token lives in the Keychain, reads never trigger paid calls, and trash
  stays sealed off.

| | PDF reader / translation plugin | Chat-with-PDF service | Paperico |
|---|---|---|---|
| Reading surface | fixed pages, overlay translation | snippet viewer | re-typeset bilingual reader + original PDF, block-accurate jumps |
| Paper understanding | — | per-file chat | TL;DR, contributions, difficulty, logic chain, method index |
| Q&A evidence | — | page-level at best | block-id citations → paragraph or PDF region |
| Across papers | — | — | merged method index in persistent, curated groups |
| Notes | manual copying | manual copying | synthesized from selected answers into Markdown with wikilinks |
| AI agent access | — | — | read-only MCP server: 10 tools + paper resources, localhost + Keychain token |
| Data & models | local files | vendor cloud | sandbox + Keychain, your own endpoints |

## What you get

- **Library** — project groups, search, sorting, bulk moves, PDF deduplication, and per-file batch import errors.
- **Tasks** — a pending/failed queue with stop, reparse and retranslate; later imports start automatically once services are configured.
- **Bilingual reader** — original and translation, logic-chain outline, method cards, PDFKit reading, saved progress.
- **Evidence chat** — attach selections, methods or figures; citations locate their source paragraph or PDF position.
- **Method groups** — persistent groups for the cross-paper method index (all eight presets visible, drag between groups, duplicate-name checks); your curated identities steer how new papers are analyzed.
- **Notes** — synthesize selected messages into Markdown notes and export them.
- **Trash** — deleting preserves PDFs, extracted content, conversations and notes until you restore or permanently delete them.
- **MCP** — opt-in localhost access with 10 read-only tools, evidence blocks and figures; copy client configuration from settings. See the [connection guide](docs/mcp.md).
- **Native desktop** — Liquid Glass, light/dark appearance, accent colors, offline math rendering, an About page with opt-in update checks, ⌘1–⌘3 navigation and ⌘, settings.

See the [release notes](docs/releases/v1.0.0.md) and the [architecture review](docs/architecture.md).

## Run

**Install:** download `Paperico-1.0.0.dmg` from the
[latest release](https://github.com/juliusloon/paperico/releases), drag Paperico into
Applications and replace any older copy. The DMG is not Developer ID signed or notarized;
distribution signing options are described in the [macOS development guide](macos/README.md).

**Build from source** — requires macOS 26+ and Xcode 26+; verified on macOS 27 / Xcode 27,
Apple Silicon:

```bash
git clone https://github.com/juliusloon/paperico.git
cd paperico
./script/build_and_run.sh
```

The script builds and opens the app and selects a standard-path Xcode if Command Line Tools
are currently selected. You can also open `macos/Paperico.xcodeproj` and run the Paperico
scheme on My Mac. The Codex Run action uses the same script.

First session:

1. Import PDFs into the library — papers are kept locally even before any service is configured.
2. In Settings, save your model endpoint, model ID and API key, then test connectivity.
3. Configure a MinerU cloud token or your self-hosted MinerU Gradio endpoint.
4. Start pending papers from the processing tasks page.
5. While reading, click evidence citations to locate their blocks or PDF positions.
6. Optionally enable Settings → MCP to let external assistants such as Claude Code,
   Cursor or VS Code read the library read-only.

**Local-first does not mean offline AI.** Cloud MinerU receives your PDF; the model endpoint
receives the text and conversation context needed for each task. The app connects directly
to your configured services. Paperico does not operate a relay.

## How it works

<p align="center">
  <img src="./assets/readme/pipeline.svg" width="100%" alt="The Paperico pipeline in five stages — import a PDF with SHA-256 deduplication, parse it with MinerU into typed blocks with positions, run one streaming LLM analysis that produces translation, roles, methods and a TL;DR, read and ask with evidence citations that jump back to the exact block or PDF region, and turn selected answers into Markdown notes — all feeding one local sandboxed library that an opt-in read-only MCP server exposes to Claude Code, Cursor and VS Code.">
</p>

| Directory | Responsibility |
|---|---|
| `macos/Paperico/App/` | Startup, dependency injection, routing, themes and native scenes |
| `macos/Paperico/Stores/` | Separate settings, project, paper, reader and chat state |
| `macos/Paperico/Core/` | Persistence, job gates, pipeline, service clients and ZIP parsing |
| `macos/Paperico/Pages/`, `Components/` | Pages, reader and reusable controls |
| `macos/Tests/`, `macos/Package.swift` | Core tests without UI startup or external API calls |
| `script/` | Repository-level build, run and verification entrypoints |
| `docs/` | Current architecture and releases |

## Data and upgrades

The sandboxed app stores its library under:

```text
~/Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico/
├── library.json          # versioned projects, papers, hashes and trash records
├── pdfs/                 # original PDFs
├── papers/<id>/          # blocks, entities, chat and notes JSON
├── mineru_output/<id>/   # extracted content and figures
├── analyses/<id>/        # raw analysis responses
└── logs/                 # optional diagnostics
```

Service configuration, appearance and progress use UserDefaults. API keys and MinerU
tokens use macOS Keychain. Storage failures are surfaced; corrupt or newer-version
indexes are not silently replaced with an empty library.

The unversioned native JSON index from the migration is compatible.
**The old backend SQLite library and Fernet credentials remain separate and are not
automatically converted.** Keep the old database and storage directory when upgrading.
Back up the entire native data directory, including trash-referenced files; credentials
require separate Keychain management.

## Validate and package

```bash
./script/check.sh                    # core tests and full app build
./script/check.sh --with-backend     # also backend tests, lint and DTO contract check (when the retired snapshot exists)
./script/build_and_run.sh --verify   # build, launch and verify the process
./macos/scripts/make_dmg.sh CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

The DMG is written to `macos/build/`. Pushing a `v*` tag also runs the
[release workflow](.github/workflows/release.yml), which builds the DMG from a clean
Release configuration and attaches it to the GitHub Release. Local builds use ad-hoc
signing and are not Developer ID notarized. See the [macOS development guide](macos/README.md)
for distribution signing options.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

[MIT](LICENSE) © 2026 juliusloon.
