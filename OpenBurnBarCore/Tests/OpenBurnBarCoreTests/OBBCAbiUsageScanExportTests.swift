import Foundation
import XCTest
// P-22 (S15): the OBBCAbi C-ABI export surface moved Core → OpenBurnBarCoreCAbi.
// This test touches only PUBLIC OBBCAbi API (OBBCAbiUsageScanExport.run,
// obb_scan_usage/obb_parse_cli_stdout/obb_string_free + the public response/request
// types), so a plain `import` suffices — no `@testable` for the C-ABI module. The
// `@testable import OpenBurnBarCore` stays for AgentProvider (Kernel-re-exported).
import OpenBurnBarCoreCAbi
@testable import OpenBurnBarCore

final class OBBCAbiUsageScanExportTests: XCTestCase {
    func test_scanReadsClaudeAndCursorFixturesWithStableRuntimeRows() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-usage-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let claude = home.appendingPathComponent(
            ".claude/projects/-Users-test-Documents-ParserContract",
            isDirectory: true
        )
        let cursor = home.appendingPathComponent(".cursor-agent/sessions", isDirectory: true)
        try fileManager.createDirectory(at: claude, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cursor, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: fixture("pc-claude-basic-session.jsonl"),
            to: claude.appendingPathComponent("claude-basic-session.jsonl")
        )
        let cursorFixture = """
        {"role":"user","content":"Inspect the Windows usage runtime","timestamp":"2026-07-10T12:00:00Z"}
        {"role":"assistant","content":"I found the parser boundary.","thinking":"Check the native bridge.","timestamp":"2026-07-10T12:00:01Z"}
        {"role":"tool","content":"File Path: `file:///C:/src/OpenBurnBar/App.xaml.cs`","timestamp":"2026-07-10T12:00:02Z"}
        """
        try Data(cursorFixture.utf8).write(
            to: cursor.appendingPathComponent("cursor-basic.jsonl"),
            options: .atomic
        )

        let request = OBBCAbiUsageScanRequest(
            supportDirectory: support.path,
            homeDirectory: home.path,
            claudeProjectsDirectory: home.appendingPathComponent(".claude/projects").path,
            codexHomeDirectory: home.path,
            cursorSessionsDirectory: cursor.path,
            factorySessionsDirectory: home.appendingPathComponent(".factory/sessions").path,
            hermesHomeDirectory: home.appendingPathComponent(".hermes").path,
            includeConversationBodies: true
        )
        let requestData = try JSONEncoder().encode(request)

        let first = try OBBCAbiUsageScanExport.run(requestData: requestData)
        let second = try OBBCAbiUsageScanExport.run(requestData: requestData)

        XCTAssertTrue(first.ok)
        XCTAssertNil(first.error)
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.claudeCode.rawValue })?.status,
            .succeeded
        )
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.cursorAgent.rawValue })?.status,
            .succeeded
        )
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.codex.rawValue })?.status,
            .missing
        )
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.claudeCode.rawValue }))
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.cursorAgent.rawValue }))
        XCTAssertFalse(first.conversations.isEmpty)
        XCTAssertEqual(first.usages.map(\.id), second.usages.map(\.id))
    }

    func test_scanRejectsIncompleteRequest() throws {
        let invalid = Data(#"{"supportDirectory":""}"#.utf8)
        XCTAssertThrowsError(try OBBCAbiUsageScanExport.run(requestData: invalid)) { error in
            XCTAssertEqual(error as? OBBCAbiUsageScanError, .invalidRequest)
        }
    }

    func test_scanReadsFactoryAndHermesFixtures() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-provider-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let factory = home.appendingPathComponent(".factory/sessions", isDirectory: true)
        let factoryProject = factory.appendingPathComponent("-Users-test-OpenBurnBar", isDirectory: true)
        let hermes = home.appendingPathComponent(".hermes", isDirectory: true)
        let hermesSessions = hermes
            .appendingPathComponent("profiles/default/sessions", isDirectory: true)
        try fileManager.createDirectory(at: factoryProject, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hermesSessions, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: fixture("pc-factory-with-settings.jsonl"),
            to: factoryProject.appendingPathComponent("factory-with-settings.jsonl")
        )
        try fileManager.copyItem(
            at: fixture("pc-factory-with-settings-settings.json"),
            to: factoryProject.appendingPathComponent("factory-with-settings.settings.json")
        )
        try fileManager.copyItem(
            at: fixture("pc-factory-with-settings-metadata.json"),
            to: factoryProject.appendingPathComponent("factory-with-settings.metadata.json")
        )
        try fileManager.copyItem(
            at: fixture("pc-hermes-session-snapshot.json"),
            to: hermesSessions.appendingPathComponent("session_cron_test_001.json")
        )

        let response = try OBBCAbiUsageScanExport.run(requestData: JSONEncoder().encode(
            request(root: root, home: home, factory: factory, hermes: hermes)
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(provider(.factory, in: response)?.status, .succeeded)
        XCTAssertEqual(provider(.hermes, in: response)?.status, .succeeded)
        XCTAssertTrue(response.usages.contains(where: { $0.provider == AgentProvider.factory.rawValue }))
        XCTAssertTrue(response.conversations.contains(where: { $0.provider == AgentProvider.factory.rawValue }))
        XCTAssertTrue(response.conversations.contains(where: { $0.provider == AgentProvider.hermes.rawValue }))
    }

    func test_scanIsolatesProviderFailure() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-provider-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let factoryFile = home.appendingPathComponent("factory-sessions-is-a-file", isDirectory: false)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: factoryFile)

        let response = try OBBCAbiUsageScanExport.run(requestData: JSONEncoder().encode(
            request(root: root, home: home, factory: factoryFile)
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(provider(.factory, in: response)?.status, .failed)
        XCTAssertNotNil(provider(.factory, in: response)?.error)
        XCTAssertTrue(response.usages.isEmpty)
    }

    func test_scanCEntryPointReturnsFailureJSONForMissingRequest() throws {
        let pointer = try XCTUnwrap(obb_scan_usage(requestJSON: nil))
        defer { obb_string_free(pointer) }

        let response = try JSONDecoder().decode(
            OBBCAbiUsageScanResponse.self,
            from: Data(String(cString: pointer).utf8)
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, OBBCAbiUsageScanError.missingRequest.description)
        XCTAssertTrue(response.providers.isEmpty)
    }

    func test_parseCEntryPointUsesSynchronousClaudeParser() throws {
        let stdout = try String(contentsOf: fixture("pc-claude-basic-session.jsonl"), encoding: .utf8)
        let provider = AgentProvider.claudeCode.rawValue
        let pointer = stdout.withCString { stdoutPointer in
            provider.withCString { providerPointer in
                obb_parse_cli_stdout(stdout: stdoutPointer, provider: providerPointer)
            }
        }
        let resultPointer = try XCTUnwrap(pointer)
        defer { obb_string_free(resultPointer) }

        let response = try JSONDecoder().decode(
            OBBCAbiParseCliStdoutResponse.self,
            from: Data(String(cString: resultPointer).utf8)
        )
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        XCTAssertFalse(response.usages.isEmpty)
        XCTAssertTrue(response.usages.allSatisfy { $0.provider == provider })
    }

    private func request(
        root: URL,
        home: URL,
        factory: URL? = nil,
        hermes: URL? = nil
    ) -> OBBCAbiUsageScanRequest {
        OBBCAbiUsageScanRequest(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true).path,
            homeDirectory: home.path,
            claudeProjectsDirectory: home.appendingPathComponent(".claude/projects", isDirectory: true).path,
            codexHomeDirectory: home.path,
            cursorSessionsDirectory: home.appendingPathComponent(".cursor-agent/sessions", isDirectory: true).path,
            factorySessionsDirectory: (factory ?? home.appendingPathComponent(".factory/sessions", isDirectory: true)).path,
            hermesHomeDirectory: (hermes ?? home.appendingPathComponent(".hermes", isDirectory: true)).path,
            includeConversationBodies: true
        )
    }

    private func provider(
        _ provider: AgentProvider,
        in response: OBBCAbiUsageScanResponse
    ) -> OBBCAbiProviderScanResult? {
        response.providers.first(where: { $0.provider == provider.rawValue })
    }

    private func fixture(_ name: String) -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot
            .appendingPathComponent("AgentLensTests/Fixtures/ParserContract", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
