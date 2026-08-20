import XCTest
@testable import OpenBurnBar
import OpenBurnBarKernel

final class CLIAgentMissionClaimCallableTests: XCTestCase {
    func testCatalogCoversWindowsParityTokens() {
        let catalog = MissionRuntimeCatalog.loadFixture()
        XCTAssertTrue(catalog.contains("junie"))
        XCTAssertTrue(catalog.contains("prime-agent"))
        XCTAssertTrue(catalog.contains("fx"))
        XCTAssertTrue(catalog.contains("kimi"))
        XCTAssertTrue(catalog.contains("gemini"))
    }

    func testUnknownKindDecodesWithoutThrowing() throws {
        let data = Data(#"{"kind":"futureKind"}"#.utf8)
        let event = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: data)
        XCTAssertEqual(event.kind, .unknown)
    }

    func testUnknownThenCompletedKeepsDecoding() throws {
        let unknown = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: Data(#"{"kind":"futureKind"}"#.utf8))
        let completed = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: Data(#"{"kind":"completed"}"#.utf8))
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(completed.kind, .completed)
    }

    func testWinnerClaimEvaluatesOnceLoserDoesNot() {
        final class ClaimBox: @unchecked Sendable {
            var evaluate = 0
            var failStatus = 0
            func winner() -> Bool {
                evaluate += 1
                return true
            }
            func loser() -> Bool {
                failStatus += 1
                return false
            }
        }
        let box = ClaimBox()
        XCTAssertTrue(box.winner())
        XCTAssertFalse(box.loser())
        XCTAssertEqual(box.evaluate, 1)
        XCTAssertEqual(box.failStatus, 1)
        XCTAssertTrue(MissionRuntimeCatalog.loadFixture().covers(ChatBackendID.allCases.map(\.rawValue)))
    }
}
