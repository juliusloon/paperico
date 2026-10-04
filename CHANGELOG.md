# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-04

### Added

- Opt-in localhost MCP access with 10 read-only tools, paper resources, figure image
  content, Keychain-backed bearer tokens and client configuration copying in settings.
- Isolated official Swift MCP SDK package and real HTTP/client interoperability tests.
- English/Chinese README pipeline diagrams and a file-by-file macOS architecture guide.
- Permanent deletion for trash entries: a per-paper confirmation removes the PDF, blocks,
  figures, chats, notes and analysis artifacts; a failed step keeps the trash entry
  retryable, and the same PDF can be imported again afterwards.
- MinerU polling tests and permanent-deletion core tests.

### Changed

- Validate Host/Origin and constrain MCP figures to active papers; reads do not change
  last-opened timestamps, expose API credentials or trigger paid service calls.
- Preserve App Sandbox and MCP server entitlements in release DMGs; run regression
  tests before publishing. The retired backend snapshot check is optional when absent.
- Validate MinerU poll responses against known task states and surface queue, page
  progress and trace IDs; cloud tasks persist a checkpoint so continue-processing
  reuses the submitted task instead of resubmitting.
- Split upload permits from cloud queueing: queued tasks no longer hold an upload
  slot, and are shown as cloud-queued while MinerU is pending.
- Reparsing a PDF now submits a fresh MinerU task instead of reusing previous results.
- Library management (tasks/trash) is a workspace overlay instead of a separate
  window, and the settings footer stays visible for long forms.

## [0.2.5] - 2026-10-03

### Changed

- Replace the application icon with the new Icon Composer artwork.
- Use the monochrome Paperico mark in the bottom-left navigation, tinted with
  the theme accent color, enlarged and without a circular background.
- Ship the current native reader, library, settings and offline renderer updates.
- Clean Release builds and validate compiled icon resources before DMG packaging.

See [the release notes](docs/releases/v0.2.5.md) for details and verification.

## [0.2.4] - 2026-10-01

### Changed

- Use one responsive reader, with a hover/pinned table of contents and restored node connectors.
- Remove side-card headers and maximize controls; present headerless frosted glass cards inline
  or in an undimmed trailing drawer while retaining the chat draft.
- Hide reader tools with the margin collapse action; use an icon-only retranslate control,
  progress ring, and consistently spaced scale controls.
- Redesign multiline chat composition and bound native history menu titles.
- Unify continuous corners, circular icon buttons, capsule controls, and explicit search actions.
- Add a live, persistent background transparency slider and numeric field.
- Keep compact navigation above drawers without reserving bottom content height.
- Overlay paper-card actions without reflow; search both paper titles and filenames.
- Add feature explanations and a first-use guide to the home page.

See [the release notes](docs/releases/v0.2.4.md) for the complete changes and verification.

## [0.2.3] - 2026-10-01

### Fixed

- Restore Charter / Iowan and Chinese serif reader typography, font scale,
  line height and bilingual paragraph spacing from the original web reader.
- Render superscripts, subscripts, inline math, aligned equations and numbered
  formulas using a bundled offline Markdown / KaTeX renderer with local fonts.
- Wrap complete logic-chain labels and method chips; remove the dashed guide.
- Start the reader at the window top without the clearance used by other pages.
- Unify information/chat card surfaces and float them over the document background;
  hide them below the available reading width and restore them when expanded.
- Track divider drags in screen coordinates, disable resize animations and save
  width preferences only when the pointer is released.
- Preserve native source citations, selections, local figures and reading progress
  across the document renderer boundary without additional model requests.

See [the release notes](docs/releases/v0.2.3.md) for validation and renderer boundaries.

## [0.2.2] - 2026-10-01

### Fixed

- Restore the home artwork below the hero text in compact windows.
- Omit Content-Type and API authorization from MinerU presigned PDF uploads,
  fixing the HTTP 403 signature mismatch in the native cloud pipeline.
- Analyze the complete MinerU text, captions and formulas in one streamed model request,
  producing translations, paragraph summaries, logic roles and the method index together.
- Remove automatic batch splitting, Reduce calls and paid JSON-repair retries; preserve
  raw responses and reject missing nodes or token-truncated output.
- Retain the full referenced paragraph in chat instead of only its 240-character preview.
- Export notes as Markdown (.md), keep the download action visible after synthesis,
  and surface synthesis/export errors.
- Show the number of nodes returned by the single analysis request, refresh reader
  status after retries, and wait for saved credentials during startup.
- Fix the JSON fallback regex crash and accept streamed objects across line boundaries.
- Add isolated upload, single-request, output-budget, failure and evidence-context tests.

See [the release notes](docs/releases/v0.2.2.md) for real-file validation.

## [0.2.1] - 2026-10-01

### Fixed

- Restore compact top spacing while retaining the existing panel style.
- Remove lingering sidebar controls during collapse; slide compact drawers in
  from outside the left edge, with navigation anchored at the bottom left.
- Align home modules to one content width and equalize recent/workflow card
  heights; remove the stray dashed line in the decorative artwork.
- Present the PDF picker from the active import sheet, remove its oversized
  focus ring, and distinguish pending setup from actual import failures.
- Read Keychain credentials off the main thread without blocking startup;
  provide an explicit settings action to request access to saved credentials.

See [the release notes](docs/releases/v0.2.1.md) for verification.

## [0.2.0] - 2026-10-01

### Changed

- Make the macOS app self-contained: native local library, processing pipeline,
  chat and notes; Python REST/SSE remains a separate compatibility component.
- Split app dependency wiring, routing and observable stores by responsibility;
  add a singleton workspace, native Settings scene and navigation shortcuts.
- Align the native setup docs and CI/DMG runner with macOS 26 / Xcode 26 requirements.

### Added

- Task management with stop/retry, pending imports without AI configuration,
  per-file batch import errors, and a recoverable trash preserving all paper data.
- Versioned JSON index, atomic actor-owned persistence, cancellation-aware FIFO
  gates, Keychain save error reporting, local ImageIO figure loading and bounded cache.
- Repository build/run/check scripts, Codex Run action, architecture review and
  25 native core regression tests in CI.

### Fixed

- Startup SIGTRAP caused by force-unwrapping the default services environment value.
- Silent storage failures, corruption treated as an empty index, lost concurrent
  session saves, and stale task cleanup racing with a retry.
- Cross-paper chat state and optimistic message IDs diverging from persisted notes.
- Invalid service URL crashes, ignored output/streaming options, token-field
  compatibility, ZIP traversal/bounds/checksum failures, and blocked reader polling.

### Upgrade notes

- Unversioned native indexes remain readable. Legacy SQLite/Fernet data is not
  automatically converted; keep the old database and storage directory.
- Native trash is retained until restored; no automatic or permanent purge is provided.

See [the release notes](docs/releases/v0.2.0.md) for verification and data boundaries.

## [0.1.0] - 2026-09-30

First open-source release.

### Added

- **Backend** (FastAPI + SQLite): paper library with projects, import dedup, soft-delete
  trash and restore; background job center with per-kind concurrency limits and
  interrupted-job reconciliation; MinerU cloud/self-hosted parsing integration
  (incl. the chemistry-structure spike); LLM services for logic-chain outlines,
  sentence-level bilingual translation, method cards, chat and note synthesis;
  evidence-cited SSE chat with attachable context; encrypted credential storage
  (Fernet); OpenAPI snapshot contract tests.
- **macOS client** (SwiftUI + PDFKit, zero third-party dependencies): full-feature
  native client on the same backend API — three-pane reader with logic-chain outline,
  bilingual/original toggle, per-block retranslation, text↔PDF switching with progress
  sync, evidence chips that jump and flash-highlight source blocks, notes mode with
  Markdown export, liquid-glass window chrome, native selection → "cite selection" chat
  integration, per-page PDF progress memory, server-address configuration;
  API-contract check script against the backend OpenAPI schema.
- **Project**: MIT license, contributing guide, code of conduct, security policy, CI
  (backend lint + tests, macOS build, secret scan), issue/PR templates,
  Dependabot, bilingual README; DMG packaging script (`macos/scripts/make_dmg.sh`)
  and an automated GitHub Release workflow on version tags; standard user-data
  containers (sandboxed Application Support + logs in the app; `start.sh --app-data`
  to keep the backend's database and PDF storage under
  `~/Library/Application Support/Paperico/`).

[Unreleased]: https://github.com/juliusloon/paperico/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/juliusloon/paperico/releases/tag/v0.3.0
[0.2.5]: https://github.com/juliusloon/paperico/releases/tag/v0.2.5
[0.1.0]: https://github.com/juliusloon/paperico/releases/tag/v0.1.0
