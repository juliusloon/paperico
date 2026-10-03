<div align="center">

# Paperico

**A local-first, bring-your-own-key native paper reading workbench.**

Import PDFs, recover their structure with MinerU, then read bilingually, follow the argument,
ask evidence-grounded questions, and turn the discussion into Markdown notes.

[![CI](https://github.com/juliusloon/paperico/actions/workflows/ci.yml/badge.svg)](https://github.com/juliusloon/paperico/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/app-v0.2.4-orange)](CHANGELOG.md)

English · [简体中文](README.zh-CN.md)

</div>

## Version 0.2.4

The reader now shares one layout at every window width, with a hover table of contents,
connected margin logic chain, and headerless glass cards that slide in from the right.
Chat has a new multiline composer and bounded history titles. Search, circular icon
controls, background transparency and home feature guides are consistent across the app.
Offline math and the single streamed full-paper analysis remain available.

The macOS app now owns its library, processing jobs, chat and notes in native code.
No Python backend is needed to run the app. This update adds task management and a
recoverable trash, and fixes startup crashes, persistence races and cancellation/retry conflicts.

See the [release notes](docs/releases/v0.2.4.md) and [architecture review](docs/architecture.md).

## Features

- Project groups, search, sorting, bulk moves, PDF deduplication, and per-file batch import errors.
- Task management with stop, reparse, and retranslate operations.
- Bilingual text, logic-chain outlines, method cards, PDFKit reading and saved progress.
- Chat with attached selections, methods or figures; valid block citations locate their evidence.
- Markdown note synthesis from selected messages and file export.
- Trash recovery preserving PDFs, extracted content, conversations and notes.
- Native Liquid Glass, light/dark appearance, accent colors, ⌘1–⌘3 navigation and ⌘, settings.

## Run

The current app target requires **macOS 26+ and Xcode 26+**. Local verification used
macOS 27 / Xcode 27 on Apple Silicon.

```bash
git clone https://github.com/juliusloon/paperico.git
cd paperico
./script/build_and_run.sh
```

The script builds and opens the app. It selects an Xcode installation at the standard
path for this invocation if Command Line Tools are currently selected. You can also
open `macos/Paperico.xcodeproj` and run the Paperico scheme on My Mac.
The Codex Run action uses the same script.

1. Import PDFs into the library, even before configuring AI services.
2. Open Settings, save your model endpoint, model ID and API key, then test connectivity.
3. Configure a MinerU cloud token or your self-hosted MinerU Gradio endpoint.
4. Start pending papers from **处理任务** (processing tasks). Later imports start automatically
   when the service configuration is ready.
5. Click evidence citations to locate their blocks or PDF positions while reading.

**Local-first does not mean offline AI.** Cloud MinerU receives your PDF; the model
endpoint receives the text and conversation context needed for each task. The app
connects directly to your configured services. Paperico does not operate a relay.

## Architecture

```text
SwiftUI pages → Observable stores → PaperLibrary / PaperPipeline / ChatService
                                         │                  │
                                  local JSON/files       MinerU / LLM
```

| Directory | Responsibility |
|---|---|
| `macos/Paperico/App/` | Startup, dependency injection, routing, themes and native scenes |
| `macos/Paperico/Stores/` | Separate settings, project, paper, reader and chat state |
| `macos/Paperico/Core/` | Persistence, job gates, pipeline, service clients and ZIP parsing |
| `macos/Paperico/Pages/`, `Components/` | Pages, reader and reusable controls |
| `macos/Tests/`, `macos/Package.swift` | Core tests without UI startup or external API calls |
| `script/` | Repository-level build, run and verification entrypoints |
| `backend/` | Retained v0.1 REST/SSE service and Python tests, independent of the app |
| `docs/` | Current architecture, releases and historical engineering records |

Ignored local `frontend/` and `design/` directories contain the retired web implementation
and design material. They are not part of the app build.

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

The unversioned native JSON index from the migration is compatible with v0.2.0.
**The old backend SQLite library and Fernet credentials remain separate and are not
automatically converted.** Keep the old database and storage directory when upgrading.
Back up the entire native data directory, including trash-referenced files; credentials
require separate Keychain management.

## Validate and package

```bash
./script/check.sh                    # core tests and full app build
./script/check.sh --with-backend     # also backend tests, lint and DTO contract check
./script/build_and_run.sh --verify   # build, launch and verify the process
./macos/scripts/make_dmg.sh CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

The DMG is written to `macos/build/Paperico-0.2.4.dmg`. Local builds use ad-hoc signing
and are not Developer ID notarized. See the [macOS development guide](macos/README.md)
for distribution signing options.

## Optional legacy API service

Users who need the independent REST/SSE API can still run `./start.sh` or follow
[backend/README.md](backend/README.md). That command starts the Python service, not the
native app. `backend/.env` and `PAPERICO_*` variables do not configure the native app.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

[MIT](LICENSE) © 2026 juliusloon.
