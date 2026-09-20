import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class HermesSquareAgentsColumnTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = HermesSquareAgentsColumnRouting.AskToMirrorPending.consume()
        for runtime in AssistantRuntimeID.allCases {
            AssistantPendingThread.shared.clear(runtime)
        }
    }

    override func tearDown() {
        for runtime in AssistantRuntimeID.allCases {
            AssistantPendingThread.shared.clear(runtime)
        }
        super.tearDown()
    }

    func testAgentsFamilyURLsLandOnCompactAgentsTab() throws {
        let urls = [
            "burnbar://hermes",
            "burnbar://chat",
            "burnbar://assistants",
            "burnbar://assistants/pi?threadId=t-pi",
            "burnbar://pi",
            "burnbar://mission/msn_1"
        ]
        for raw in urls {
            let routed = MobileOsIntegrationPolicy.route(url: try XCTUnwrap(URL(string: raw)))
            XCTAssertEqual(
                HermesSquareAgentsColumnRouting.compactDestination(for: routed.destination),
                .hermes,
                raw
            )
        }
        XCTAssertEqual(AuroraNavDestination.hermes.trayLabel, "Agents")
        XCTAssertTrue(AuroraNavDestination.trayDestinations(compact: true).contains(.hermes))
    }

    func testShowAssistantsTabSelectsAgentsForEveryRuntime() {
        XCTAssertTrue(HermesSquareAgentsColumnRouting.selectsAgentsTab(notificationRuntime: nil))
        XCTAssertTrue(HermesSquareAgentsColumnRouting.selectsAgentsTab(notificationRuntime: "hermes"))
        XCTAssertTrue(HermesSquareAgentsColumnRouting.selectsAgentsTab(notificationRuntime: "pi"))
        XCTAssertTrue(HermesSquareAgentsColumnRouting.selectsAgentsTab(notificationRuntime: "codex"))
        XCTAssertTrue(HermesSquareAgentsColumnRouting.selectsAgentsTab(notificationRuntime: "claude"))
    }

    func testInboxIDsMatchMacThreadIdentity() {
        XCTAssertEqual(
            HermesSquareAgentsColumnRouting.inboxID(runtime: .hermes, threadID: " burnbar-ios-e2e "),
            "hermes:burnbar-ios-e2e"
        )
        XCTAssertEqual(
            HermesSquareAgentsColumnRouting.inboxID(runtime: .pi, threadID: "pi-thread"),
            "pi:pi-thread"
        )
        XCTAssertEqual(
            HermesSquareAgentsColumnRouting.inboxID(runtime: .codex, threadID: "cli-sess"),
            "cli:cli-sess"
        )
        XCTAssertNil(HermesSquareAgentsColumnRouting.inboxID(runtime: .hermes, threadID: "   "))
    }

    func testConsumePendingRouteOpensPiAndCLIThreads() {
        AssistantPendingThread.shared.stash(assistant: .pi, threadID: " pi-1 ")
        let pi = HermesSquarePendingThreadRoute.consumePendingRoute()
        XCTAssertEqual(pi?.runtime, .pi)
        XCTAssertEqual(pi?.inboxID, "pi:pi-1")
        XCTAssertNil(HermesSquarePendingThreadRoute.consumePendingRoute())

        AssistantPendingThread.shared.stash(assistant: .claude, threadID: "claude-sess")
        let cli = HermesSquarePendingThreadRoute.consumePendingRoute()
        XCTAssertEqual(cli?.runtime, .claude)
        XCTAssertEqual(cli?.inboxID, "cli:claude-sess")
    }

    func testHermesInboxHelperStillMatchesExistingTests() {
        XCTAssertEqual(
            HermesSquarePendingThreadRoute.hermesInboxID(for: " gateway-thread-123 "),
            "hermes:gateway-thread-123"
        )
        AssistantPendingThread.shared.stash(assistant: .hermes, threadID: " gateway-thread-123 ")
        XCTAssertEqual(
            HermesSquarePendingThreadRoute.consumeHermesInboxID(),
            "hermes:gateway-thread-123"
        )
        XCTAssertNil(HermesSquarePendingThreadRoute.consumeHermesInboxID())
    }

    func testOverflowHoldsWandMissionsResumeGrantsRollback() {
        let overflow = HermesSquareAgentsColumnRouting.overflowDestinations
        XCTAssertTrue(overflow.contains(.switcher))
        XCTAssertTrue(overflow.contains(.wand))
        XCTAssertTrue(overflow.contains(.missions))
        XCTAssertTrue(overflow.contains(.resumeHandoff))
        XCTAssertTrue(overflow.contains(.capabilityGrants))
        XCTAssertTrue(overflow.contains(.rollback))
        XCTAssertFalse(overflow.map(\.rawValue).contains { $0.localizedCaseInsensitiveContains("grokd") })
        XCTAssertFalse(overflow.map(\.rawValue).contains { $0.contains("1337") })
    }

    func testAskToMirrorPendingStashThenConsumeOnce() {
        HermesSquareAgentsColumnRouting.AskToMirrorPending.stash()
        XCTAssertTrue(HermesSquareAgentsColumnRouting.AskToMirrorPending.consume())
        XCTAssertFalse(HermesSquareAgentsColumnRouting.AskToMirrorPending.consume())
    }

    func testGrokdIsNamedNotShippedOnPhone() {
        XCTAssertFalse(HermesSquareAgentsColumnRouting.includesGrokdOnPhone)
        XCTAssertEqual(
            HermesSquareAgentsColumnRouting.grokdRelayOperationName,
            "HermesRelayOperation.grokdLocalBox"
        )
        let address = HermesSquareAgentsColumnRouting.grokdMobileAddress
        XCTAssertTrue(address.contains("HermesRelayOperation.grokdLocalBox"))
        XCTAssertTrue(address.contains(":1337"))
        XCTAssertTrue(address.contains("openburnbar-daemon.sock"))
        XCTAssertTrue(address.contains("Mac only"))
    }
}
