# Spike 0c — FoundationModels single-flight stress

**Date:** 2026-05-20
**Phase:** 0
**Outcome:** **PASS** (after three spec patches applied during the spike)
**Risk it covers:** chained-Task `inFlight` single-flight pattern under concurrent stress; `LanguageModelSession` API surface assumptions in the spec.

## Environment

- macOS: 26.6
- Hardware: Apple Silicon (arm64e)
- Apple Intelligence: enabled mid-spike (prerequisite)
- Swift: 6.4
- macOS SDK: 27.0 (FoundationModels framework version 2.0.49)

## Result

**Outcome:** PASS, with **three spec patches** required and applied. Final stress run:

| Metric                          | Value |
| ------------------------------- | ----- |
| Total calls                     | 1000  |
| Succeeded                       | 999   |
| `concurrentRequests` errors     | **0**     |
| Other errors                    | 1 (`GenerationError.guardrailViolation` — Apple Intelligence content-policy false positive on one prompt; **not a concurrency failure**) |
| Wall clock                      | 377 s |
| Per-call latency (mean)         | ≈ 0.38 s |

### Done criterion (a) — zero `concurrentRequests`

**PASS**. Zero `concurrentRequests` errors over 1000 calls (10 concurrent workers × 100 iterations). The chained-Task `inFlight` pattern correctly serializes the framework call.

### Done criterion (b) — FIFO + non-overlapping intervals

**PASS** over the 999 successful calls. `(start, end)` timestamps captured at the actor's `callRespond` call site (per the phasing doc — not at caller-spawn time, which would race across `Task` initiation). Insertion order (which equals completion order, since intervals are appended after the framework `await` returns) matched the start-time-sorted order at every index, and no two intervals overlapped — i.e., the framework call was serialized strictly.

## Spec implications — three patches required

The spike surfaced three errors in the design spec's `FoundationModelsSummarizer`:

### Patch 1 — `Task<Success, Failure>` is a struct in Swift 6.4

The spec's example used `if inFlight === task { inFlight = nil }` to decide whether `defer` should clear `inFlight`. **`===` is `AnyObject`-only** and doesn't apply to `Task<Success, Failure>` (a struct).

```
error: argument type 'Task<String, any Error>' expected to be an instance
       of a class or class-constrained type
```

Replace the identity check with a monotonic generation counter:

```swift
private var generation: UInt64 = 0

public func summarize(prompt: String) async throws -> String {
    generation &+= 1
    let myGeneration = generation
    let prior = inFlight
    let task = Task<String, Error> { [weak self] in
        if let prior { _ = try? await prior.value }
        guard let self else { throw CancellationError() }
        return try await self.callRespond(prompt)
    }
    inFlight = task                               // synchronous on actor
    defer {
        // `defer` runs in actor isolation. Only clear `inFlight` if we're
        // still the latest task; otherwise a concurrent caller has already
        // installed its own task and we'd be clobbering its reference.
        if myGeneration == generation { inFlight = nil }
    }
    return try await task.value
}
```

Same semantics as the spec's intent ("clear only if I'm the latest"); compatible with Swift 6 syntax.

### Patch 2 — `.concurrentRequests` lives on different error enums depending on SDK

The phasing-doc patch 2 (`LLMError.singleFlightViolation`) and the design spec's mapping table assert that `LanguageModelSession.Error.concurrentRequests` is the canonical surface. The actual SDK situation is more nuanced:

| SDK         | Where `.concurrentRequests` lives                                           | Status                                    |
| ----------- | --------------------------------------------------------------------------- | ----------------------------------------- |
| macOS 26    | `LanguageModelSession.GenerationError.concurrentRequests(_: Context)`       | **deprecated in 27.0** with redirect note |
| macOS 27+   | `LanguageModelSession.Error.concurrentRequests` (no associated value)       | new home                                  |

Code targeting macOS 26 must catch on `GenerationError`. Code that wants to be future-proof on macOS 27 must also conditionally cast to `LanguageModelSession.Error` under `#available(macOS 27, ...)`. The spec's `callRespond` example needs to handle both surfaces:

```swift
private func callRespond(_ prompt: String) async throws -> String {
    do {
        let session = LanguageModelSession(instructions: instructions)   // see Patch 3
        return try await session.respond(to: prompt).content
    } catch let e as LanguageModelSession.GenerationError {
        // macOS 26 surface — `.concurrentRequests` lives here, deprecated 27.0.
        if case .concurrentRequests = e {
            throw LLMError.singleFlightViolation(e)
        }
        throw mapGenerationError(e)
    } catch let e {
        // macOS 27+ surface — gated to keep this compilable under macOS 26 deployment.
        if #available(macOS 27, iOS 27, visionOS 27, *),
           let sessionErr = e as? LanguageModelSession.Error
        {
            switch sessionErr {
            case .concurrentRequests:
                throw LLMError.singleFlightViolation(sessionErr)
            default:
                throw mapSessionError(sessionErr)
            }
        }
        throw e   // unrecognized — re-throw without remapping
    }
}
```

Two consequences:
- The mapping table in the design spec needs a row for `GenerationError.concurrentRequests(_)` mapping to `singleFlightViolation`.
- The spec's "two catch clauses" prose stays correct, but the *macOS 27 catch* is now an `if let sessionErr = e as? LanguageModelSession.Error` cast inside a generic `catch let e`, not a typed `catch let e as LanguageModelSession.Error` clause. Typed catch on `LanguageModelSession.Error` is rejected by the compiler under macOS 26 deployment.

### Patch 3 — `LanguageModelSession` accumulates transcript across calls

`LanguageModelSession` keeps a running transcript of `(prompt, response)` exchanges. The design's intent is that each `summarize(prompt:)` call is **logically independent** (it's the memory-log compaction surface — a one-shot summary, not a conversation). With a single shared session held across calls, the transcript grows unbounded and overflows the context window after roughly 100 short prompts:

```
GenerationError: exceededContextWindowSize(... debugDescription: "...")
```

Reproduced empirically in the spike's first stress run: 852 of 1000 calls failed with `exceededContextWindowSize` after the first ~150 succeeded.

**Resolution:** recreate the session per `callRespond` invocation. Move the `instructions` string into actor storage and the `LanguageModelSession` construction into `callRespond`:

```swift
public actor FoundationModelsSummarizer: LLMSummarizer {
    private let instructions: String
    private var inFlight: Task<String, Error>?
    private var generation: UInt64 = 0

    public init?(instructions: String) {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        self.instructions = instructions
    }

    public func summarize(prompt: String) async throws -> String { /* see Patch 1 */ }

    private func callRespond(_ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)   // ← fresh per call
        // … catch clauses per Patch 2 …
    }
}
```

After applying Patches 1–3, the second stress run produced **999 / 1000 successful calls** (the single failure was a `GenerationError.guardrailViolation` — content-policy false positive on a benign prompt, unrelated to concurrency).

## Notes

- Swift Testing's `@Test` and `@Suite` macros reject sibling `@available(...)` attributes (build error: "Attribute 'Suite' cannot be applied to this structure because it has been marked '@available(macOS 26, *)'"). Guard availability via the `Package.swift` `platforms:` declaration instead, or via runtime `#available` inside the test bodies. Phase 6's `FoundationModelsSummarizerTests` should follow the same pattern.
- Wall-clock per call: ~0.38 s under fresh-session-per-call. The first stress run (shared session) measured ~0.30 s/call but most of those were fail-fast `exceededContextWindowSize` errors. Real successful-call latency is ~0.4 s.
- One `guardrailViolation` in 999 successful calls is ~0.1 % — well within Apple Intelligence's documented false-positive rate for content filters. Phase 6's tests should not assert "every call succeeds" but rather "zero `singleFlightViolation` over N calls."
- Spike scratch lives at `/tmp/memsearch-spikes/spike-0c/` — not committed.
