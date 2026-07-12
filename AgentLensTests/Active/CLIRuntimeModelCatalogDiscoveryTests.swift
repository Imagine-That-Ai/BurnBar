import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

final class CLIRuntimeModelCatalogDiscoveryTests: XCTestCase {
    func testCursorAgentFallsBackToLegacyModelListingAfterPrimaryProbeFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cursor-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("cursor-agent")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "models" ]; then
          echo "primary catalog unavailable" >&2
          exit 17
        fi
        if [ "${1:-}" = "--list-models" ]; then
          printf 'Available models\\nauto - Auto (default)\\ngpt-5.4-high - GPT 5.4 High\\n'
          exit 0
        fi
        exit 64
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolver = CLIExecutableResolver(
            environmentProvider: { ["PATH": root.path, "SHELL": "/bin/false"] },
            homeDirectoryProvider: { root.path }
        )
        let discovery = CLIRuntimeModelCatalogDiscovery(
            resolver: resolver,
            gatewayProvider: {
                XCTFail("Cursor Agent catalog discovery must not query the OpenBurnBar gateway")
                return RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
            }
        )

        let response = try await discovery.modelCatalog(
            for: CLIRuntimeModelCatalogRequest(runtime: AssistantRuntimeID.cursorAgent.rawValue)
        )

        XCTAssertEqual(response.runtime, AssistantRuntimeID.cursorAgent.rawValue)
        XCTAssertEqual(response.options.map(\.modelID), ["auto", "gpt-5.4-high"])
        XCTAssertEqual(Set(response.options.map(\.source)), [.cursorAgentModelCatalog])
    }

    func testCursorAgentUsesDefaultProfileWhenBothModelListingCommandsFail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cursor-catalog-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("cursor-agent")
        let script = """
        #!/bin/sh
        echo "catalog unavailable for ${1:-unknown}" >&2
        exit 17
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolver = CLIExecutableResolver(
            environmentProvider: { ["PATH": root.path, "SHELL": "/bin/false"] },
            homeDirectoryProvider: { root.path }
        )
        let discovery = CLIRuntimeModelCatalogDiscovery(
            resolver: resolver,
            gatewayProvider: {
                XCTFail("Cursor Agent catalog discovery must not query the OpenBurnBar gateway")
                return RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
            }
        )

        let response = try await discovery.modelCatalog(
            for: CLIRuntimeModelCatalogRequest(runtime: AssistantRuntimeID.cursorAgent.rawValue)
        )

        XCTAssertEqual(response.options.count, 1)
        XCTAssertEqual(response.options.first?.modelID, "")
        XCTAssertEqual(response.options.first?.source, .cursorAgentProfile)
        XCTAssertEqual(response.options.first?.providerID, "cursor")
        XCTAssertEqual(response.options.first?.displayName.contains("Cursor Agent default"), true)
    }
}
