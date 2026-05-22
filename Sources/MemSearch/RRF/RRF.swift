package enum RRF {
    package static func fuse(_ rankings: [[ChunkID]], k: Int = 60, topK: Int) -> [(ChunkID, Float)] {
        var raw: [ChunkID: Float] = [:]
        for ranking in rankings {
            for (rank, id) in ranking.enumerated() {
                raw[id, default: 0] += 1.0 / Float(k + rank + 1)
            }
        }
        let theoreticalMax = Float(rankings.count) / Float(k + 1)
        return raw.map { ($0.key, $0.value / theoreticalMax) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
            .prefix(topK)
            .map { $0 }
    }
}
