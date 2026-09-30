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
- **Web client** (React 19 + Vite + Tailwind 4 + Zustand): three-pane reader with
  logic-chain outline, bilingual/original toggle, font scaling, per-block retranslation,
  text↔PDF (pdf.js) switching with progress sync; evidence chips that jump and
  flash-highlight source blocks; notes mode with Markdown export; settings for
  LLM/MinerU/appearance; responsive layouts for narrow viewports.
- **macOS client** (SwiftUI + PDFKit, zero third-party dependencies): 1:1 feature port of
  the web client on the same backend API, liquid-glass window chrome, native selection →
  "cite selection" chat integration, per-page PDF progress memory, server-address
  configuration; API-contract check script against the backend OpenAPI schema.
- **Project**: MIT license, contributing guide, code of conduct, security policy, CI
  (backend lint + tests, web lint + build, macOS build), issue/PR templates,
  Dependabot, bilingual README.

[Unreleased]: https://github.com/juliusloon/paperico/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/juliusloon/paperico/releases/tag/v0.1.0
