import XCTest
import OpenBurnBarComputerUseCore

final class CLIAgentMissionAttachmentRefTests: XCTestCase {
    func testInitRoundTrip() throws {
        let ref = CLIAgentMissionAttachmentRef(
            id: "att-1",
            contentBlake3: String(repeating: "ab", count: 32),
            displayName: "notes.txt",
            byteCount: 12,
            transport: "cloud",
            contentKeyBase64: "QQ=="
        )
        XCTAssertEqual(ref.id, "att-1")
        XCTAssertEqual(ref.displayName, "notes.txt")
        XCTAssertEqual(ref.byteCount, 12)
        XCTAssertEqual(ref.transport, "cloud")
        XCTAssertEqual(ref.contentKeyBase64, "QQ==")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(CLIAgentMissionAttachmentRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }
}
