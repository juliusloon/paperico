# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/juliusloon/paperico/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/juliusloon/paperico/releases/tag/v0.1.0
