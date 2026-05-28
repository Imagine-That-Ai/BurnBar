import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Kept outside `@MainActor` CLIAgentSessionMirrorTests so parity checks do not
/// inherit the app-host MainActor queue (which can wedge after long suites).
final class CLIAgentEligibleProviderParityTests: XCTestCase {
    func testPythonSwiftEligibleSetParity() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = repoRoot
            .appendingPathComponent("tools/openburnbar-mcp/eligible_providers.json")
        let data = try Data(contentsOf: configURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nativeEligible = try XCTUnwrap(object["native_eligible"] as? [String: String])

        let swiftEligible = Set(AgentProvider.allCases.compactMap { provider -> String? in
            guard let agent = CLIAgentSessionMirror.archivedAgent(for: provider),
                  CLIAgentSessionMirror.canResume(agent: agent) else {
                return nil
            }
            return provider.rawValue
        })

        XCTAssertEqual(Set(nativeEligible.keys), swiftEligible)
    }
}
