# Documentation

Engineering notes and design records for Paperico. The user-facing docs live in the
root [`README.md`](../README.md) / [`README.zh-CN.md`](../README.zh-CN.md).

| Document | Topic |
|---|---|
| [agentero-lessons-for-paperico.md](agentero-lessons-for-paperico.md) | Engineering analysis that shaped the backend roadmap (job governance, shared LLM client, config hygiene) |
| [agentero-execution-plan.md](agentero-execution-plan.md) | Task-by-task execution plan derived from the analysis (job center, reconcile, chat context) |
| [bbox-coordinate-system.md](bbox-coordinate-system.md) | The block bounding-box coordinate system used for PDF highlighting |
| [storage-migration-and-ui.md](storage-migration-and-ui.md) | Storage layout, reference migration and the related UI work |
| [mineru-chem-integration-spike.md](mineru-chem-integration-spike.md) | Spike on integrating MinerU chemistry-structure parsing |
| [macos-window-and-reader-perf.md](macos-window-and-reader-perf.md) | macOS window chrome and reader performance investigation (2026-09) |

Conventions:

- Internal planning documents that contain personal paths or reading lists are **not**
  part of the public repository.
- Verification logs/screenshots (with paper contents) stay local under
  `docs/verification/` (gitignored).
