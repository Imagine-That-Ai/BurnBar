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
}
