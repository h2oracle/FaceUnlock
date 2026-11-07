import Foundation

/// Small, allocation-light vector helpers for face embeddings.
public enum VectorMath {
    /// Returns `v / |v|`. A zero vector is returned unchanged (it can never
    /// match anything, because its cosine with any vector is 0).
    public static func l2Normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for x in v { sumSquares += x * x }
        let norm = sumSquares.squareRoot()
        guard norm > 0, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity in [-1, 1]. Mismatched lengths, empty vectors or a
    /// zero vector yield 0 (i.e. "no match") rather than crashing.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0, denom.isFinite else { return 0 }
        return max(-1, min(1, dot / denom))
    }

    /// L2-normalised mean of L2-normalised vectors (the "centroid" template).
    public static func normalizedMean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        guard vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors {
            let n = l2Normalized(v)
            for i in 0..<n.count { sum[i] += n[i] }
        }
        return l2Normalized(sum)
    }
}
