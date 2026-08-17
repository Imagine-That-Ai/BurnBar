import Foundation

/// 64-bit SimHash over normalized word tokens.
///
/// Stage 0 of the usage-memory funnel needs a repetition signal ("the member
/// keeps asking variants of this") and a cheap near-duplicate pre-check that
/// costs no allocation-heavy NLP and no model call. SimHash gives both: near-
/// identical texts land in the same (or Hamming-adjacent) bucket, and the
/// store indexes the value (`memory_usage_candidates.simhash`) for O(log n)
/// repetition lookups. Semantic near-dup detection happens later, at Stage 2,
/// with embeddings — this is deliberately the dumb, free tier.
public enum UsageMemorySimHash {
    /// FNV-1a 64 over one token — stable across runs and platforms, no seeding.
    private static func tokenHash(_ token: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Compute the 64-bit SimHash of `text` over lowercased alphanumeric word
    /// tokens. Empty/whitespace-only input hashes to 0.
    public static func hash(_ text: String) -> UInt64 {
        var counts = [Int](repeating: 0, count: 64)
        var sawToken = false
        for token in text.lowercased().split(whereSeparator: { $0.isLetter == false && $0.isNumber == false }) {
            sawToken = true
            let h = tokenHash(token)
            for bit in 0..<64 {
                if (h >> UInt64(bit)) & 1 == 1 {
                    counts[bit] += 1
                } else {
                    counts[bit] -= 1
                }
            }
        }
        guard sawToken else { return 0 }
        var result: UInt64 = 0
        for bit in 0..<64 where counts[bit] > 0 {
            result |= (1 << UInt64(bit))
        }
        return result
    }

    /// Hamming distance between two SimHash values (0 = same bucket).
    public static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// The signed representation stored in SQLite's INTEGER column.
    public static func storageValue(_ hash: UInt64) -> Int64 {
        Int64(bitPattern: hash)
    }
}
