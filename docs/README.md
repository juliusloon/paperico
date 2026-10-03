# Documentation

Current architecture, release notes, and historical engineering records for Paperico. The user-facing docs live in the
root [`README.md`](../README.md) / [`README.zh-CN.md`](../README.zh-CN.md).

| Document | Topic |
|---|---|
| [architecture.md](architecture.md) | Current native architecture, repository review, reliability fixes, validation and remaining work |
| [releases/v0.2.4.md](releases/v0.2.4.md) | Unified responsive reader, glass drawers, transparency settings and search |
| [releases/v0.2.3.md](releases/v0.2.3.md) | Reader typography, offline math, floating side cards and pointer-based divider input |
| [releases/v0.2.2.md](releases/v0.2.2.md) | Single-request translation and analysis, MinerU upload, compact artwork and complete real-file workflow validation |
| [releases/v0.2.1.md](releases/v0.2.1.md) | Layout, sidebar animation, PDF import and credential startup fixes |
| [releases/v0.2.0.md](releases/v0.2.0.md) | Native app update and upgrade/data guidance |
| [agentero-lessons-for-paperico.md](agentero-lessons-for-paperico.md) | Engineering analysis that shaped the backend roadmap (job governance, shared LLM client, config hygiene) |
| [agentero-execution-plan.md](agentero-execution-plan.md) | Task-by-task execution plan derived from the analysis (job center, reconcile, chat context) |
| [bbox-coordinate-system.md](bbox-coordinate-system.md) | The block bounding-box coordinate system used for PDF highlighting |
| [storage-migration-and-ui.md](storage-migration-and-ui.md) | Storage layout, reference migration and the related UI work |
| [mineru-chem-integration-spike.md](mineru-chem-integration-spike.md) | Spike on integrating MinerU chemistry-structure parsing |
| [macos-window-and-reader-perf.md](macos-window-and-reader-perf.md) | macOS window chrome and reader performance investigation (2026-09) |

Earlier backend/web plans describe the v0.1 architecture; use architecture.md and the
root READMEs for current runtime and data ownership.

Conventions:

- Internal planning documents that contain personal paths or reading lists are **not**
  part of the public repository.
- Verification logs/screenshots (with paper contents) stay local under
  `docs/verification/` (gitignored).
