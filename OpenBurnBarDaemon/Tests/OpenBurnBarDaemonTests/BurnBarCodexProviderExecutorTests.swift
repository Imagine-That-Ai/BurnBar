@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarCodexProviderExecutorTests: XCTestCase {
    func testSanitizedEnvironmentUsesOnlyTrustedCLIPathEntries() {
        let environment = BurnBarCodexProviderExecutor.sanitizedEnvironment(apiKey: "")
        let path = environment["PATH"] ?? ""
        let entries = path.split(separator: ":").map(String.init)

        XCTAssertEqual(entries, BurnBarCodexSystemProcessRunner.trustedCLIPathEntries())
        XCTAssertFalse(entries.contains { $0.contains("/.nvm/") })
        XCTAssertFalse(entries.contains { $0.hasSuffix("/.local/bin") })
        XCTAssertTrue(entries.contains("/usr/bin"))
    }

    func testTrustedCLIPathEntriesExcludeHomeManagedBins() {
        let home = URL(fileURLWithPath: "/Users/example")
        let entries = BurnBarCodexSystemProcessRunner.trustedCLIPathEntries(home: home)

        XCTAssertFalse(entries.contains("/Users/example/.local/bin"))
        XCTAssertFalse(entries.contains("/Users/example/.nvm/versions/node/v22.0.0/bin"))
        XCTAssertEqual(entries, ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    }

    func testTrustedExecutablePathAcceptsHomebrewSymlinkTargets() {
        let home = URL(fileURLWithPath: "/Users/example")

        XCTAssertTrue(
            BurnBarCodexSystemProcessRunner.isTrustedExecutablePath(
                "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
                home: home
            )
        )
        XCTAssertTrue(
            BurnBarCodexSystemProcessRunner.isTrustedExecutablePath(
                "/usr/local/lib/node_modules/@openai/codex/bin/codex.js",
                home: home
            )
        )
        XCTAssertFalse(
            BurnBarCodexSystemProcessRunner.isTrustedExecutablePath(
                "/Users/example/.local/bin/codex",
                home: home
            )
        )
    }

    func testStreamingResponsesBodyEmitsItemLifecycleBeforeTextDelta() throws {
        let body = try BurnBarCodexProviderExecutor.responsesBody(
            modelID: "gpt-5.6-sol",
            output: "ping",
            stream: true
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("event: response.created"), text)
        XCTAssertTrue(text.contains("event: response.output_item.added"), text)
        XCTAssertTrue(text.contains("event: response.content_part.added"), text)
        XCTAssertTrue(text.contains("event: response.output_text.delta"), text)
        XCTAssertTrue(text.contains(#""delta":"ping""#), text)
        XCTAssertTrue(text.contains("\"item_id\""), text)
        XCTAssertTrue(text.contains("event: response.output_text.done"), text)
        XCTAssertTrue(text.contains("event: response.content_part.done"), text)
        XCTAssertTrue(text.contains("event: response.output_item.done"), text)
        XCTAssertTrue(text.contains("event: response.completed"), text)

        let created = text.range(of: "event: response.created")!
        let itemAdded = text.range(of: "event: response.output_item.added")!
        let delta = text.range(of: "event: response.output_text.delta")!
        XCTAssertLessThan(created.lowerBound, itemAdded.lowerBound)
        XCTAssertLessThan(itemAdded.lowerBound, delta.lowerBound)
    }
}
