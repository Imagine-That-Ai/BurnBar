import OpenBurnBarCore
import XCTest

final class OpenBurnBarErrorTests: XCTestCase {
    func test_metricKeyUsesDomainAndCode() {
        let error = OpenBurnBarError.sync("permission_denied", message: "Firestore rules rejected write.")
        XCTAssertEqual(error.metricKey, "sync_permission_denied")
    }

    func test_inferSyncMapsPermissionErrors() {
        let error = OpenBurnBarError.inferSync(from: "Missing or insufficient permissions.")
        XCTAssertEqual(error.domain, .sync)
        XCTAssertEqual(error.code, "permission_denied")
    }

    func test_logMetadataIncludesDomainCodeAndMessage() {
        let error = OpenBurnBarError.database("migration_failed", message: "Schema v42 failed.")
        XCTAssertEqual(error.logMetadata["domain"], "database")
        XCTAssertEqual(error.logMetadata["code"], "migration_failed")
        XCTAssertEqual(error.logMetadata["message"], "Schema v42 failed.")
    }

    func test_logParserProtocolIsSendable() {
        func acceptsParser(_ parser: any LogParserProtocol) -> AgentProvider {
            parser.provider
        }
        XCTAssertEqual(acceptsParser(StubLogParser()), .claudeCode)
    }
}

private struct StubLogParser: LogParserProtocol {
    let provider: AgentProvider = .claudeCode
}
