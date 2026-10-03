<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Paperico — a local-first, bring-your-own-key native macOS paper reading workbench. Import a paper, read it bilingually, question it with evidence, and turn the discussion into notes. The Paperico app icon, a blue P over a gray O, sits on the right.">
</p>

<div align="center">

[![CI](https://github.com/juliusloon/paperico/actions/workflows/ci.yml/badge.svg)](https://github.com/juliusloon/paperico/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/badge/download-v0.2.5-0A84FF)](https://github.com/juliusloon/paperico/releases)

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

## What you get

- **Library** — project groups, search, sorting, bulk moves, PDF deduplication, and per-file batch import errors.
- **Tasks** — a pending/failed queue with stop, reparse and retranslate; later imports start automatically once services are configured.
- **Bilingual reader** — original and translation, logic-chain outline, method cards, PDFKit reading, saved progress.
- **Evidence chat** — attach selections, methods or figures; citations locate their source paragraph or PDF position.
- **Notes** — synthesize selected messages into Markdown notes and export them.
- **Trash** — deleting preserves PDFs, extracted content, conversations and notes until you restore them.
- **Native desktop** — Liquid Glass, light/dark appearance, accent colors, offline math rendering, ⌘1–⌘3 navigation and ⌘, settings.

## What's new in v0.2.5

- New Icon Composer app icon, and the monochrome Paperico mark in navigation.
- Installable `Paperico-0.2.5.dmg` attached to the GitHub Release by the new release workflow.
- All v0.2.1–v0.2.4 reader, library, chat and offline-renderer updates in one native app.

See the [release notes](docs/releases/v0.2.5.md) and the [architecture review](docs/architecture.md).

## Run

**Install:** download `Paperico-0.2.5.dmg` from the
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

**Local-first does not mean offline AI.** Cloud MinerU receives your PDF; the model endpoint
receives the text and conversation context needed for each task. The app connects directly
to your configured services. Paperico does not operate a relay.

## How it works

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

The DMG is written to `macos/build/Paperico-0.2.5.dmg`. Pushing a `v*` tag also runs the
[release workflow](.github/workflows/release.yml), which builds the DMG from a clean
Release configuration and attaches it to the GitHub Release. Local builds use ad-hoc
signing and are not Developer ID notarized. See the [macOS development guide](macos/README.md)
for distribution signing options.

## Optional legacy API service

Users who need the independent REST/SSE API can still run `./start.sh` or follow
[backend/README.md](backend/README.md). That command starts the Python service, not the
native app. `backend/.env` and `PAPERICO_*` variables do not configure the native app.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

[MIT](LICENSE) © 2026 juliusloon.
