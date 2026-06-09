import XCTest
@testable import OpenBurnBarCore

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

    func testUnknownCountIsNoOp() throws {
        // Streaming completions that do not declare a total (chunkCount <= 0) keep
        // the prior behavior — no false positive.
        var v = ChunkReassemblyValidator()
        for s in [0, 2] { try v.record(sequence: s) } // a gap, but count unknown
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: 0))
        XCTAssertNoThrow(try v.validateComplete(declaredChunkCount: -1))
    }
}
