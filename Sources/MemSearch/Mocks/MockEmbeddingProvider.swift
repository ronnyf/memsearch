import Foundation
import CryptoKit
import os

package final class MockEmbeddingProvider: EmbeddingProvider {
    package nonisolated let modelName: String = "mock"
    package nonisolated let dimension: Int

    package struct State: Sendable {
        package var injectedFailures: [String: EmbeddingError] = [:]
        package var latencyPerBatch: Duration? = nil
        package var callCount: Int = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    package init(
        dimension: Int = 8,
        injectedFailures: [String: EmbeddingError] = [:],
        latencyPerBatch: Duration? = nil
    ) {
        self.dimension = dimension
        self.lock = OSAllocatedUnfairLock(initialState: .init(
            injectedFailures: injectedFailures,
            latencyPerBatch: latencyPerBatch,
            callCount: 0
        ))
    }

    package func embed(_ texts: [String]) async throws -> [Embedding] {
        // The lock is taken in short sections only — never held across the
        // `Task.sleep(for:)` await — so concurrent `embed` calls don't
        // serialize on it. `callCount` is bumped in a separate critical
        // section per call (interleaving across concurrent calls is fine for
        // a counter; tests only assert it from a sequential context).
        let (failures, latency) = lock.withLock { ($0.injectedFailures, $0.latencyPerBatch) }
        if let latency { try await Task.sleep(for: latency) }
        if let first = texts.first, let injected = failures[first] {
            lock.withLock { $0.callCount += 1 }
            throw injected
        }
        lock.withLock { $0.callCount += 1 }
        return try texts.map {
            try Embedding(values: hashToFloats($0, dim: dimension), expectedDimension: dimension)
        }
    }

    package var callCount: Int { lock.withLock { $0.callCount } }

    /// Deterministic seed from `s` via SHA-256.
    /// `Hasher` is process-randomized (different vectors across runs); we need
    /// run-stable output for golden tests + cross-checks. First 8 bytes of
    /// SHA-256(s) seed SplitMix64; clamped to non-zero (golden-ratio constant)
    /// since 0 is a fixed point of xor-shift family RNGs.
    private func hashToFloats(_ s: String, dim: Int) -> [Float] {
        let digest = SHA256.hash(data: Data(s.utf8))
        var seed: UInt64 = 0
        for byte in digest.prefix(8) { seed = (seed << 8) | UInt64(byte) }
        if seed == 0 { seed = 0x9E3779B97F4A7C15 }
        var rng = SplitMix64(state: seed)
        return (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }
    }
}

/// SplitMix64 — accepts any seed including 0 once shifted, no degenerate
/// fixed points. Reference: https://prng.di.unimi.it/splitmix64.c
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
