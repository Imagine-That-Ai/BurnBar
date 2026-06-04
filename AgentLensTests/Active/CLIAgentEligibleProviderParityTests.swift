import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Kept outside `@MainActor` CLIAgentSessionMirrorTests so parity checks do not
/// inherit the app-host MainActor queue (which can wedge after long suites).
final class CLIAgentEligibleProviderParityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Static parity check; fail fast if the app-host runner regresses.
        executionTimeAllowance = 30
    }

    func testPythonSwiftEligibleSetParity() throws {
        let configURL = try bundledResourceURL(named: "eligible_providers", extension: "json")
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

    private func bundledResourceURL(named name: String, extension ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(
            bundle.url(forResource: name, withExtension: ext),
            "Missing bundled CLI agent parity fixture: \(name).\(ext)"
        )
    }
}
