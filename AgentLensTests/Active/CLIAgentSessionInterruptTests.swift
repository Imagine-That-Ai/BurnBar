import XCTest
@testable import OpenBurnBar
import OpenBurnBarKernel

@MainActor
final class CLIAgentSessionInterruptTests: XCTestCase {
    func testInterruptStopsRegisteredSessionWithoutHalt() async throws {
        var halted = false
        var interrupted = false
        CLIAgentSessionInterruptBus.register(sessionID: "sess-1") {
            interrupted = true
        }
        struct Unused: Error {}
        let dispatcher = CLIAgentSessionActionDaemonDispatcher(
            resumeRunner: { _, _, _, _ in throw Unused() },
            haltHandler: { halted = true }
        )
        let response = try await dispatcher.perform(
            CLIAgentSessionActionRequest(sessionID: "sess-1", action: .interrupt)
        )
        XCTAssertEqual(response.status, .interrupted)
        XCTAssertTrue(interrupted)
        XCTAssertFalse(halted)
    }

    func testComposerInterruptUsesACPBusIdNotComputerUseSession() async throws {
        var interrupted = false
        CLIAgentSessionInterruptBus.register(sessionID: "acp-grok-test") {
            interrupted = true
        }
        let dispatcher = CLIAgentSessionActionDaemonDispatcher(
            resumeRunner: { _, _, _, _ in throw NSError(domain: "test", code: 1) },
            haltHandler: { }
        )
        let response = try await dispatcher.perform(
            CLIAgentSessionActionRequest(sessionID: "acp-grok-test", action: .interrupt)
        )
        XCTAssertEqual(response.status, .interrupted)
        XCTAssertTrue(interrupted)
    }
}
