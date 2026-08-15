import Foundation
import XCTest

@testable import BurnBar

/// Regression coverage for CLIBridge's process ownership across cancelled
/// generations. An older completion must not clear a newer process pointer.
@MainActor
final class CLIBridgeGenerationTests: XCTestCase {
    func testLateCancelledCompletionCannotClearNewerProcessPointer() {
        let cancelledProcess = Process()
        let newerProcess = Process()

        XCTAssertFalse(
            CLIBridge.ownsRunningProcess(newerProcess, completedProcess: cancelledProcess),
            "a cancelled generation's completion cannot clear the newer owner"
        )
        XCTAssertTrue(
            CLIBridge.ownsRunningProcess(newerProcess, completedProcess: newerProcess),
            "the current generation's completion clears its own owner"
        )
    }
}
