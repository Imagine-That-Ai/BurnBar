import XCTest
// B1: CLIAgentRuntime is public in OpenBurnBarKernelCrypto — plain import.
import OpenBurnBarKernelCrypto
@testable import OpenBurnBarKernelModels

/// Verifies OpenClaude (github.com/Gitlawb/openclaude — a spawned Claude Code fork)
/// is a first-class provider that is *distinct* from OpenClaw
/// (github.com/openclaw/openclaw — a separate AI-assistant platform). These two
/// were once conflated; these tests lock in that they never collide on the wire.
final class OpenClaudeProviderTests: XCTestCase {

    // MARK: - Distinct identities

    func test_openClaudeAndOpenClawAreDistinctProviders() {
        XCTAssertNotEqual(AgentProvider.openClaude, AgentProvider.openClaw)
        XCTAssertNotEqual(AssistantRuntimeID.openClaude, AssistantRuntimeID.openClaw)
        XCTAssertNotEqual(CLIAgentRuntime.openClaude, CLIAgentRuntime.openClaw)
    }

    // MARK: - Stable wire tokens (persisted in UserDefaults / Firestore / relay)

    func test_assistantRuntimeID_wireTokens() {
        XCTAssertEqual(AssistantRuntimeID.openClaude.rawValue, "openclaude")
        XCTAssertEqual(AssistantRuntimeID.openClaw.rawValue, "openclaw")
    }

    func test_cliAgentRuntime_wireTokens() {
        XCTAssertEqual(CLIAgentRuntime.openClaude.rawValue, "openclaude")
        XCTAssertEqual(CLIAgentRuntime.openClaw.rawValue, "openclaw")
    }

    func test_agentProvider_rawValueAndPersistedToken() {
        XCTAssertEqual(AgentProvider.openClaude.rawValue, "OpenClaude")
        XCTAssertEqual(AgentProvider.openClaude.displayName, "OpenClaude")
        XCTAssertEqual(AgentProvider.openClaude.persistedToken, "openclaude")
        XCTAssertEqual(AgentProvider.openClaw.persistedToken, "openclaw")
    }

    // MARK: - Codable round-trips (no cross-contamination)

    func test_assistantRuntimeID_codableRoundTrip() throws {
        for runtime in [AssistantRuntimeID.openClaude, .openClaw] {
            let data = try JSONEncoder().encode(runtime)
            let decoded = try JSONDecoder().decode(AssistantRuntimeID.self, from: data)
            XCTAssertEqual(decoded, runtime)
        }
    }

    // MARK: - Catalog resolution

    func test_fromCatalogProviderID_resolvesEachDistinctly() {
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("openclaude"), .openClaude)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("open-claude"), .openClaude)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("openclaw"), .openClaw)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("open-claw"), .openClaw)
    }

    // MARK: - Runtime mirroring (OpenClaude sessions mirror to mobile, like other CLIs)

    func test_cliAgentRuntime_mirrorsOpenClaudeAssistant() {
        XCTAssertEqual(CLIAgentRuntime(assistant: .openClaude), .openClaude)
        XCTAssertEqual(CLIAgentRuntime.openClaude.assistantRuntime, .openClaude)
    }

    // MARK: - Identity surfaces

    func test_openClaude_hasLogoIconAndMobileSurface() {
        XCTAssertEqual(AgentProvider.openClaude.bundledLogoName, "OpenClaudeLogo")
        XCTAssertFalse(AgentProvider.openClaude.iconName.isEmpty)
        XCTAssertTrue(AssistantRuntimeID.openClaude.hasMobileChatSurface)
        XCTAssertTrue(AgentProvider.swarmGlyphProviders.contains(.openClaude))
    }
}
