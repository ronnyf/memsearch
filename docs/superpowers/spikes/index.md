# Phase 0 Spikes — Index

**Date:** 2026-05-20
**Status:** **3/3 spikes PASS** (Spike 0c: PASS after three spec patches applied during the spike)

| Spike | Topic | Outcome | Result note |
| ----- | ----- | ------- | ----------- |
| 0a    | GRDB 7.x + sqlite-vec + reader concurrency | **PASS** | [`2026-05-20-spike-0a-sqlite-vec.md`](2026-05-20-spike-0a-sqlite-vec.md) |
| 0b    | swift-transformers Core ML + actor init shape | **PASS** (load-bearing) + PARTIAL (end-to-end .mlpackage load deferred to Phase 2 entry) | [`2026-05-20-spike-0b-coreml-bge.md`](2026-05-20-spike-0b-coreml-bge.md) |
| 0c    | FoundationModels single-flight stress | **PASS** (after 3 spec patches) — 999/1000 succeeded, zero `singleFlightViolation`, FIFO + non-overlapping | [`2026-05-20-spike-0c-foundationmodels.md`](2026-05-20-spike-0c-foundationmodels.md) |

## Pinned Python ground-truth fixture

**Status:** **deferred to Phase 1 entry** — corpus + queries are committed in `tests/fixtures/python-baseline/`, but `python-top5.json` + `manifest.json` + `python-top5.json.sha256` remain to be generated. Blocked at Phase 0 by network sandbox: `huggingface.co` was added to allowlist mid-spike, but `cdn-lfs.huggingface.co` / `cas-server.xethub.hf.co` (where the actual model weights live) require additional allowlisting before the embedder model can be downloaded. Phase 1 entry checklist tracks this — see `docs/superpowers/phases/phase-0-notes.md`.

The fixture is referenced by Phase 1 (criterion 6 cross-check), Phase 3 (SwiftData success criterion), and Phase 5 (per-embedder success criterion). All three deferrals carry forward: those criteria become "if the fixture is pinned, also cross-check; else document the defer."

## Spec patches applied during Phase 0

| Commit    | Reason |
| --------- | ------ |
| `eb74e49` | Close gaps in design spec before Phase 0 spikes (`callRespond` second catch clause, `MockEmbeddingProvider.latencyPerBatch`) |
| `2f5a923` | Spike 0a — replace `load_extension('vec0')` with direct `sqlite3_vec_init()` call; resolve "sqlite-vec distribution" open question (source-link via custom SwiftPM wrapper) |
| `ca7dd71` | Spike 0c — three findings: `Task<S,F>` is a struct in Swift 6 (use generation counter); `.concurrentRequests` lives on different error enums by SDK (macOS 26 vs 27); `LanguageModelSession` accumulates a transcript across calls (recreate session per `callRespond`) |

## Phase 0 exit verdict

**PASS — proceed to Phase 1** with these conditions:
- The design spec is coherent against all three spike outcomes.
- Phase 1's plan must include: pin the Python ground-truth fixture as one of its first tasks (Phase 0 deferred this).
- Phase 2's plan must include: identify a concrete Core ML embedding model (BGE-M3 vs MiniLM-L6 vs other) — Spike 0b deferred end-to-end `.mlpackage` loading until a real default is chosen.
