import XCTest
@testable import OpenBurnBarCore

/// Locks OMP / Oh My Pi identity on the shared wire tokens used by relay,
/// Firestore, and catalog resolution — distinct from OpenClaude and OpenClaw.
final class OMPProviderTests: XCTestCase {

    func test_ompAndOpenClaudeAreDistinctProviders() {
        XCTAssertNotEqual(AgentProvider.omp, AgentProvider.openClaude)
        XCTAssertNotEqual(AgentProvider.omp, AgentProvider.openClaw)
        XCTAssertNotEqual(AssistantRuntimeID.omp, AssistantRuntimeID.openClaude)
        XCTAssertNotEqual(CLIAgentRuntime.omp, CLIAgentRuntime.openClaude)
    }

    func test_assistantRuntimeID_and_cliAgentRuntime_wireTokens() {
        XCTAssertEqual(AssistantRuntimeID.omp.rawValue, "omp")
        XCTAssertEqual(CLIAgentRuntime.omp.rawValue, "omp")
    }

    func test_agentProvider_rawValueAndPersistedToken() {
        XCTAssertEqual(AgentProvider.omp.rawValue, "OMP")
        XCTAssertEqual(AgentProvider.omp.displayName, "OMP")
        XCTAssertEqual(AgentProvider.omp.persistedToken, "omp")
    }

    func test_fromCatalogProviderID_resolvesOmpAliases() {
        let aliases = ["omp", "ohmypi", "oh-my-pi", "oh my pi"]
        for alias in aliases {
            XCTAssertEqual(AgentProvider.fromCatalogProviderID(alias), .omp, "catalog alias: \(alias)")
        }
    }

    func test_fromPersistedToken_resolvesCanonicalOmpToken() {
        XCTAssertEqual(AgentProvider.fromPersistedToken("omp"), .omp)
        XCTAssertEqual(AgentProvider.fromPersistedToken("OMP"), .omp)
    }

    func test_cliAgentRuntime_mirrorsOmpAssistant() {
        XCTAssertEqual(CLIAgentRuntime(assistant: .omp), .omp)
        XCTAssertEqual(CLIAgentRuntime.omp.assistantRuntime, .omp)
    }

    func test_omp_hasLogoIconAndMobileSurface() {
        XCTAssertEqual(AgentProvider.omp.bundledLogoName, "OMPLogo")
        XCTAssertFalse(AgentProvider.omp.iconName.isEmpty)
        XCTAssertTrue(AssistantRuntimeID.omp.hasMobileChatSurface)
        XCTAssertTrue(AgentProvider.swarmGlyphProviders.contains(.omp))
    }
}
