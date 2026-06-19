import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// F-3: memory citation resolver — tap affordance classification + canonical
/// source selection. The invariant is "never a dead link": a live citation
/// without a device-local jump id degrades to cross-device, and a pruned/
/// tombstoned source shows unavailable.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class MemoryCitationResolverTests: XCTestCase {

    private func citation(
        id: String = "cite-1",
        messageID: String? = "msg-1",
        crossDeviceHMAC: String = "hmac-1",
        state: MemoryCitationState = .live
    ) -> MemoryCitation {
        MemoryCitation(
            id: id,
            threadLogicalID: "thread-logical-1",
            messageID: messageID,
            role: "assistant",
            authoredAt: Date(timeIntervalSince1970: 1_750_000_000),
            contentHash: "hash-\(id)",
            crossDeviceHMAC: crossDeviceHMAC,
            citationState: state
        )
    }

    // MARK: - Affordance

    func testLiveWithMessageIDIsJumpable() {
        XCTAssertEqual(
            MemoryCitationResolver.affordance(for: citation(messageID: "msg-X")),
            .jumpToLocal(messageID: "msg-X")
        )
    }

    func testLiveWithoutMessageIDIsCrossDevice() {
        XCTAssertEqual(
            MemoryCitationResolver.affordance(for: citation(messageID: nil)),
            .crossDeviceOnly
        )
    }

    func testLiveWithEmptyMessageIDIsCrossDevice() {
        XCTAssertEqual(
            MemoryCitationResolver.affordance(for: citation(messageID: "")),
            .crossDeviceOnly,
            "An empty messageID must not produce a jump to nothing."
        )
    }

    func testSourcePrunedIsUnavailable() {
        XCTAssertEqual(
            MemoryCitationResolver.affordance(for: citation(state: .sourcePruned)),
            .sourceUnavailable
        )
    }

    func testTombstonedIsUnavailable() {
        XCTAssertEqual(
            MemoryCitationResolver.affordance(for: citation(state: .tombstoned)),
            .sourceUnavailable
        )
    }

    // MARK: - Canonical + extra

    func testCanonicalPrefersLiveJumpable() {
        let crossOnly = citation(id: "a", messageID: nil)
        let jumpable = citation(id: "b", messageID: "msg-b")
        let result = MemoryCitationResolver.canonicalAndExtra(from: [crossOnly, jumpable])
        XCTAssertEqual(result?.canonical.id, "b")
        XCTAssertEqual(result?.extraCount, 1)
    }

    func testCanonicalExtraCountForManySources() {
        let cites = (0..<4).map { citation(id: "c\($0)", messageID: "m\($0)") }
        let result = MemoryCitationResolver.canonicalAndExtra(from: cites)
        XCTAssertEqual(result?.extraCount, 3)
    }

    func testCanonicalFallsBackToFirstWhenNoJumpable() {
        let a = citation(id: "a", messageID: nil)
        let b = citation(id: "b", messageID: nil)
        let result = MemoryCitationResolver.canonicalAndExtra(from: [a, b])
        XCTAssertEqual(result?.canonical.id, "a")
        XCTAssertEqual(result?.extraCount, 1)
    }

    func testCanonicalEmptyReturnsNil() {
        XCTAssertNil(MemoryCitationResolver.canonicalAndExtra(from: []))
    }

    // MARK: - Labels

    func testLabelJumpable() {
        XCTAssertEqual(MemoryCitationResolver.label(for: .jumpToLocal(messageID: "m")), "Source message")
    }

    func testLabelCrossDevice() {
        XCTAssertEqual(MemoryCitationResolver.label(for: .crossDeviceOnly), "Source on another device")
    }

    func testLabelSourceUnavailable() {
        XCTAssertEqual(MemoryCitationResolver.label(for: .sourceUnavailable), "Source no longer available")
    }

    func testLabelWithExtraCount() {
        XCTAssertEqual(
            MemoryCitationResolver.label(for: .jumpToLocal(messageID: "m"), extraCount: 2),
            "Source message  +2 more"
        )
    }
}
