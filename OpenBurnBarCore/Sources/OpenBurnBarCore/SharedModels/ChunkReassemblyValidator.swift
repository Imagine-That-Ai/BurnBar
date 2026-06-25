import Foundation

/// # F4 — chunked-response integrity on reassembly
///
/// A relay-forwarded response arrives as `response.chunk` frames (each carrying a
/// `sequence`) terminated by a `response.complete` frame that declares the total
/// `chunkCount`. Every chunk's ciphertext is AES-GCM sealed with its `sequence`
/// bound into the AAD, so a relay/MITM **cannot** forge, modify, or re-sequence a
/// chunk — a duplicate of a given sequence is byte-identical and therefore
/// idempotent. What the seal does **not** prevent is a relay **dropping** a chunk:
/// the historical reassembly (`fragments[sequence] = payload`, then sort+join)
/// silently truncated the result when a sequence was missing.
///
/// This validator closes that gap. The consumer records each received chunk's
/// sequence and, on `response.complete`, calls ``validateComplete(declaredChunkCount:)``;
/// a gap or a trailing drop is surfaced as an error instead of an undetected
/// truncation. It is a pure value type so every branch is unit-testable, and it is
/// shared by the iroh, WSS, and host reassembly paths for identical behavior.
public struct ChunkReassemblyValidator: Sendable, Equatable {
    public enum ValidationError: Error, Equatable, Sendable {
        /// A chunk arrived with a negative sequence — malformed/protocol violation.
        case negativeSequence(Int)
        /// A completion frame followed one or more chunks without declaring a
        /// positive total. Without that boundary, a relay could drop trailing
        /// chunks and make an incomplete response look valid.
        case missingDeclaredChunkCount(declaredChunkCount: Int, distinctReceived: Int)
        /// A completion frame declared a total lower than a sequence already
        /// received. That means the terminal boundary no longer covers the
        /// observed chunk stream.
        case chunkAfterDeclaredEnd(declaredChunkCount: Int, sequence: Int, distinctReceived: Int)
        /// `response.complete` declared `declaredChunkCount` chunks but at least one
        /// in-range sequence was never received; `firstMissing` is the lowest gap.
        case incompleteResponse(declaredChunkCount: Int, distinctReceived: Int, firstMissing: Int)
    }

    private var seen: Set<Int> = []

    public init() {}

    /// The number of distinct chunk sequences recorded so far.
    public var distinctChunkCount: Int { seen.count }

    /// Whether `sequence` was already recorded (a duplicate). Duplicates are safe
    /// to ignore because the sealed payload for a given sequence is byte-identical.
    public func hasSeen(_ sequence: Int) -> Bool { seen.contains(sequence) }

    /// Record a received chunk's sequence. Throws on a negative sequence; a
    /// duplicate is accepted idempotently (returns without error).
    public mutating func record(sequence: Int) throws {
        guard sequence >= 0 else { throw ValidationError.negativeSequence(sequence) }
        seen.insert(sequence)
    }

    /// Validate that every chunk `0..<declaredChunkCount` was received.
    ///
    /// - Parameter declaredChunkCount: the count from the `response.complete`
    ///   frame. A non-positive count is only accepted for an empty response. Once
    ///   chunks have arrived, the terminal boundary must declare a positive total.
    /// - Throws: ``ValidationError/incompleteResponse(declaredChunkCount:distinctReceived:firstMissing:)``
    ///   when an in-range sequence is missing (a dropped/withheld chunk).
    public func validateComplete(declaredChunkCount: Int) throws {
        guard declaredChunkCount > 0 else {
            guard seen.isEmpty else {
                throw ValidationError.missingDeclaredChunkCount(
                    declaredChunkCount: declaredChunkCount,
                    distinctReceived: seen.count
                )
            }
            return
        }
        if let outOfRangeSequence = seen.filter({ $0 >= declaredChunkCount }).min() {
            throw ValidationError.chunkAfterDeclaredEnd(
                declaredChunkCount: declaredChunkCount,
                sequence: outOfRangeSequence,
                distinctReceived: seen.count
            )
        }
        for sequence in 0..<declaredChunkCount where !seen.contains(sequence) {
            throw ValidationError.incompleteResponse(
                declaredChunkCount: declaredChunkCount,
                distinctReceived: seen.count,
                firstMissing: sequence
            )
        }
    }
}
