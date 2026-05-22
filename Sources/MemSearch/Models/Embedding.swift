public struct Embedding: Sendable {
    public let values: [Float]
    public var dimension: Int { values.count }

    /// - Postcondition: `values.count == expectedDimension`.
    public init(values: [Float], expectedDimension: Int) throws(EmbeddingError) {
        guard values.count == expectedDimension else {
            throw .dimensionMismatch(expected: expectedDimension, got: values.count)
        }
        self.values = values
    }
}
// NOT Hashable — [Float] hashing has NaN reflexivity hazards and large
// vectors are expensive to hash. See spec line 154.
