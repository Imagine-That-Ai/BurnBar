import XCTest
@testable import OpenBurnBarKernelModels

/// F4: a relay that drops a `response.chunk` must be caught on reassembly rather
/// than silently truncating the result.
final class ChunkReassemblyValidatorTests: XCTestCase {
    func testCompleteContiguousStreamValidates() throws {
        var v = ChunkReassemblyValidator()
        for s in 0..<5 { try v.record(sequence: s) }
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: 5))
        XCTAssertEqual(v.distinctChunkCount, 5)
    }

    func testTrailingDropIsDetected() throws {
        // Relay withholds the last chunk: received 0..3, complete declares 5.
        var v = ChunkReassemblyValidator()
        for s in 0..<4 { try v.record(sequence: s) }
        XCTAssertThrowsError(try v.validateComplete(declaredChunkCount: 5)) { error in
            XCTAssertEqual(
                error as? ChunkReassemblyValidator.ValidationError,
                .incompleteResponse(declaredChunkCount: 5, distinctReceived: 4, firstMissing: 4)
            )
        }
    }

    func testInternalGapIsDetected() throws {
        // Relay drops chunk 2: received 0,1,3,4.
        var v = ChunkReassemblyValidator()
        for s in [0, 1, 3, 4] { try v.record(sequence: s) }
        XCTAssertThrowsError(try v.validateComplete(declaredChunkCount: 5)) { error in
            XCTAssertEqual(
                error as? ChunkReassemblyValidator.ValidationError,
                .incompleteResponse(declaredChunkCount: 5, distinctReceived: 4, firstMissing: 2)
            )
        }
    }

    func testDuplicatesAreIdempotentAndDoNotFalsePositive() throws {
        // Relay replays chunk 1 twice — sealed payload is byte-identical, so it is
        // a no-op and must not be mistaken for completeness.
        var v = ChunkReassemblyValidator()
        for s in [0, 1, 1, 2] { try v.record(sequence: s) }
        XCTAssertEqual(v.distinctChunkCount, 3)
        XCTAssertTrue(v.hasSeen(1))
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: 3))
    }

    func testReorderedDeliveryStillValidates() throws {
        var v = ChunkReassemblyValidator()
        for s in [3, 0, 4, 1, 2] { try v.record(sequence: s) }
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: 5))
    }

    func testNegativeSequenceIsRejected() {
        var v = ChunkReassemblyValidator()
        XCTAssertThrowsError(try v.record(sequence: -1)) { error in
            XCTAssertEqual(error as? ChunkReassemblyValidator.ValidationError, .negativeSequence(-1))
        }
    }

    func testMissingDeclaredCountFailsAfterChunks() throws {
        var v = ChunkReassemblyValidator()
        for s in [0, 1] { try v.record(sequence: s) }
        XCTAssertThrowsError(try v.validateComplete(declaredChunkCount: 0)) { error in
            XCTAssertEqual(
                error as? ChunkReassemblyValidator.ValidationError,
                .missingDeclaredChunkCount(declaredChunkCount: 0, distinctReceived: 2)
            )
        }
        XCTAssertThrowsError(try v.validateComplete(declaredChunkCount: -1)) { error in
            XCTAssertEqual(
                error as? ChunkReassemblyValidator.ValidationError,
                .missingDeclaredChunkCount(declaredChunkCount: -1, distinctReceived: 2)
            )
        }
    }

    func testDeclaredCountMustCoverObservedSequences() throws {
        var v = ChunkReassemblyValidator()
        for s in [0, 1, 2] { try v.record(sequence: s) }
        XCTAssertThrowsError(try v.validateComplete(declaredChunkCount: 2)) { error in
            XCTAssertEqual(
                error as? ChunkReassemblyValidator.ValidationError,
                .chunkAfterDeclaredEnd(declaredChunkCount: 2, sequence: 2, distinctReceived: 3)
            )
        }
    }

    func testEmptyCompletionCanOmitDeclaredCount() throws {
        let v = ChunkReassemblyValidator()
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: 0))
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: -1))
    }
}
