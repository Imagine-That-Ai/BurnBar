import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Regression tests proving that the `AssistantPendingThread.shared` singleton
/// is reset between test invocations via the `setUp`/`tearDown` clear pattern
/// (mirrors `OpenBurnBarMobileTests.setUp/tearDown`).
///
/// XCTest runs methods within a class in alphabetical order. The
/// "…StashIsClearedBetweenTests" methods stash a value and assert it is present
/// *without consuming*; the alphabetically-next method asserts the slot is
/// `nil` at the start, proving that `setUp`'s `clear()` call wiped the state
/// left behind by the prior test.
@MainActor
final class AssistantPendingThreadIsolationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AssistantPendingThread.shared.clear(.hermes)
        AssistantPendingThread.shared.clear(.pi)
    }

    override func tearDown() async throws {
        AssistantPendingThread.shared.clear(.hermes)
        AssistantPendingThread.shared.clear(.pi)
        try await super.tearDown()
    }

    // MARK: - Consume semantics

    /// Runs first alphabetically. Stash, consume (returns the value), then
    /// consume again — the second call must return `nil` because the first
    /// consume cleared the slot.
    func test_pendingThreadConsumeClearsSlot() {
        // setUp should have cleared all slots.
        XCTAssertNil(AssistantPendingThread.shared.hermes)
        XCTAssertNil(AssistantPendingThread.shared.pi)

        AssistantPendingThread.shared.stash(assistant: .hermes, threadID: "hermes-thread-1")
        XCTAssertEqual(AssistantPendingThread.shared.consume(.hermes), "hermes-thread-1")
        // Second consume must return nil — the slot was cleared by the first.
        XCTAssertNil(AssistantPendingThread.shared.consume(.hermes))
    }

    // MARK: - Cross-test isolation (hermes)

    /// Runs second alphabetically. Stashes a hermes thread ID and asserts it
    /// is present via the non-consuming accessor (`.hermes`). The value is
    /// intentionally left in the slot so the next test can verify that
    /// `setUp` cleared it.
    func test_pendingThreadHermesStashIsClearedBetweenTests() {
        // setUp cleared all slots (including any state left by the prior test).
        XCTAssertNil(AssistantPendingThread.shared.hermes)
        XCTAssertNil(AssistantPendingThread.shared.pi)

        AssistantPendingThread.shared.stash(assistant: .hermes, threadID: "hermes-leaked")
        XCTAssertEqual(AssistantPendingThread.shared.hermes, "hermes-leaked")
    }

    // MARK: - Cross-test isolation (pi)

    /// Runs third alphabetically. The previous test left a hermes value in the
    /// slot. Asserts that hermes is now `nil` — proving `setUp`'s
    /// `clear(.hermes)` wiped the leaked state. Then stashes a pi value and
    /// asserts it is present (again without consuming).
    func test_pendingThreadPiStashIsClearedBetweenTests() {
        // The previous test left a hermes value. setUp should have cleared it.
        XCTAssertNil(AssistantPendingThread.shared.hermes)

        AssistantPendingThread.shared.stash(assistant: .pi, threadID: "pi-leaked")
        XCTAssertEqual(AssistantPendingThread.shared.pi, "pi-leaked")
    }

    // MARK: - Whitespace trimming

    /// Runs fourth alphabetically. The previous test left a pi value in the
    /// slot. Asserts that pi is now `nil` — proving `setUp`'s `clear(.pi)`
    /// wiped the leaked state. Then verifies that `stash` trims leading and
    /// trailing whitespace before storing the thread ID.
    func test_pendingThreadStashTrimsWhitespace() {
        // The previous test left a pi value. setUp should have cleared it.
        XCTAssertNil(AssistantPendingThread.shared.pi)

        AssistantPendingThread.shared.stash(assistant: .hermes, threadID: "  trimmed-hermes  ")
        let consumed = AssistantPendingThread.shared.consume(.hermes)
        XCTAssertEqual(consumed, "trimmed-hermes")
    }
}
