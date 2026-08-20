import XCTest
import OpenBurnBarKernel

final class ACPStdioClientTests: XCTestCase {
    func testGrokAndKimiLaunchArgvMatchDecisionRecord() {
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "grok"), ["agent", "stdio"])
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "kimi"), ["acp"])
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "agy"), [])
    }

    func testRefuseAutoAcceptModes() {
        XCTAssertThrowsError(try ACPStdioClient.refuseAutoAcceptMode("yolo"))
        XCTAssertThrowsError(try ACPStdioClient.refuseAutoAcceptMode("allow_always"))
        XCTAssertThrowsError(try ACPStdioClient.refuseAutoAcceptMode("auto"))
        XCTAssertNoThrow(try ACPStdioClient.refuseAutoAcceptMode("default"))
    }

    func testLineScannerKeepsLeftoverAfterFirstNewline() {
        let scanner = ACPStdioClient.LineScanner()
        let chunk = Data("{\"id\":1,\"result\":{\"sessionId\":\"s1\"}}\n{\"id\":2,\"result\":{\"ok\":true}}\n".utf8)
        scanner.feedForTests(chunk)
        XCTAssertEqual(scanner.drainLineForTests(), "{\"id\":1,\"result\":{\"sessionId\":\"s1\"}}")
        XCTAssertEqual(scanner.drainLineForTests(), "{\"id\":2,\"result\":{\"ok\":true}}")
        XCTAssertNil(scanner.drainLineForTests())
    }
}
