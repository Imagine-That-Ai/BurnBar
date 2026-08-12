import Foundation
import OpenBurnBarKernel
import XCTest

final class UsageExecutionSourceTests: XCTestCase {
    func testProviderLogInferenceDistinguishesRuntimeFromProvider() {
        let grokBuild = TokenUsage(
            provider: .xAI,
            sessionId: "grok-session",
            projectName: "BurnBar",
            model: "grok-4",
            inputTokens: 10,
            outputTokens: 5,
            startTime: Date(timeIntervalSince1970: 1),
            endTime: Date(timeIntervalSince1970: 2),
            usageSource: .providerLog
        )
        XCTAssertEqual(grokBuild.executionSourceID, "grok-build")
        XCTAssertEqual(grokBuild.executionSourceName, "Grok Build")
        XCTAssertEqual(grokBuild.executionSourceKind, .cli)
        XCTAssertEqual(grokBuild.executionSourceConfidence, .derivedExact)

        let unattributedGateway = TokenUsage(
            provider: .xAI,
            sessionId: "gateway-session",
            projectName: "OpenBurnBar Gateway",
            model: "grok-4",
            inputTokens: 10,
            outputTokens: 5,
            startTime: Date(timeIntervalSince1970: 1),
            endTime: Date(timeIntervalSince1970: 2),
            usageSource: .daemon
        )
        XCTAssertEqual(unattributedGateway.executionSourceID, "unknown")
        XCTAssertEqual(unattributedGateway.executionSourceConfidence, .unknown)
    }

    func testClientMarkersNormalizeWithoutPersistingRawUserAgent() {
        let cursor = UsageExecutionSourceResolver.fromClientMarker("Cursor/1.2.3 Darwin arm64")
        XCTAssertEqual(cursor?.id, "cursor")
        XCTAssertEqual(cursor?.name, "Cursor")
        XCTAssertEqual(cursor?.kind, .ide)

        let desktop = UsageExecutionSourceResolver.fromClientMarker("Codex Desktop/2026.7")
        XCTAssertEqual(desktop?.id, "codex-desktop")
        XCTAssertEqual(desktop?.kind, .desktopApp)

        let safari = UsageExecutionSourceResolver.fromClientMarker("openburnbar-safari-extension")
        XCTAssertEqual(safari?.id, "openburnbar-safari-extension")
        XCTAssertEqual(safari?.name, "OpenBurnBar Safari Extension")
        XCTAssertEqual(safari?.kind, .desktopApp)
        XCTAssertNil(
            UsageExecutionSourceResolver.fromClientMarker(
                "openburnbar-safari-extension-impostor",
                allowCustom: false
            )
        )

        XCTAssertNil(UsageExecutionSourceResolver.fromClientMarker("Mozilla/5.0 unrelated-client"))
        XCTAssertNil(UsageExecutionSourceResolver.fromClientMarker("Mozilla/5.0 (Linux; Android 16)"))

        let custom = UsageExecutionSourceResolver.fromClientMarker(
            "acme-workbench/4.2 build-17",
            allowCustom: true
        )
        XCTAssertEqual(custom?.id, "acme-workbench")
        XCTAssertEqual(custom?.name, "Acme Workbench")
        XCTAssertEqual(custom?.kind, .unknown)

        let spacedCustom = UsageExecutionSourceResolver.fromClientMarker(
            "Visual Studio Code/1.0",
            allowCustom: true
        )
        XCTAssertEqual(spacedCustom?.id, "visual-studio-code")
        XCTAssertEqual(spacedCustom?.name, "Visual Studio Code")
    }

    func testExplicitSourceOverridesProviderLogInference() {
        let usage = TokenUsage(
            provider: .codex,
            sessionId: "desktop-session",
            projectName: "BurnBar",
            model: "gpt-5.6-codex",
            inputTokens: 100,
            outputTokens: 25,
            startTime: Date(timeIntervalSince1970: 1),
            endTime: Date(timeIntervalSince1970: 2),
            executionSourceID: "codex-desktop",
            executionSourceName: "Codex Desktop",
            executionSourceKind: .desktopApp,
            executionSourceConfidence: .exact
        )
        XCTAssertEqual(usage.executionSourceID, "codex-desktop")
        XCTAssertEqual(usage.executionSourceConfidence, .exact)
    }
}
