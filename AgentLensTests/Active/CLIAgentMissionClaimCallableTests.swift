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
}
