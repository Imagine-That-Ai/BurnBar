import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class TextExpansionRewriteBoundaryTests: XCTestCase {
    func test_textExpansionRewriteGatewaysAreLoopbackOnly() {
        XCTAssertTrue(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "http://127.0.0.1:8642")!))
        XCTAssertTrue(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "https://localhost:8642/v1")!))
        XCTAssertTrue(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "http://[::1]:8765")!))

        XCTAssertFalse(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "https://gateway.example.com")!))
        XCTAssertFalse(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "http://10.0.0.5:8765")!))
        XCTAssertFalse(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "http://localhost.attacker.example:8642")!))
        XCTAssertFalse(ChatSessionController.allowsTextExpansionRewriteGateway(URL(string: "http://user:pass@127.0.0.1:8642")!))
    }

    func test_textExpansionRewriteRejectsCLIAssistantBackendsBeforeGatewayUse() async throws {
        for backend in ChatBackendID.allCases where backend.requiresCLIAssistantConsent {
            let controller = try makeController()
            controller.chatBackend = backend

            do {
                _ = try await controller.rewriteTextExpansionSnippet(Self.sampleSnippet())
                XCTFail("Expected LLM snippet rewrite to reject \(backend.displayName)")
            } catch TextExpansionRewriteError.unsupportedBackend(let name) {
                XCTAssertEqual(name, backend.displayName)
            } catch {
                XCTFail("Unexpected error for \(backend.displayName): \(error)")
            }
        }
    }

    func test_textExpansionRewriteRejectsNonLocalGatewayBeforeNetworkUse() async throws {
        let settings = SettingsManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)")))
        settings.hermesGatewayBaseURL = "https://gateway.example.com"
        let controller = try makeController(settings: settings)
        controller.chatBackend = .hermes

        do {
            _ = try await controller.rewriteTextExpansionSnippet(Self.sampleSnippet())
            XCTFail("Expected non-local Hermes gateway to be rejected before the HTTP request is built")
        } catch TextExpansionRewriteError.nonLocalGatewayURL(let name) {
            XCTAssertEqual(name, ChatBackendID.hermes.displayName)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeController(settings: SettingsManager? = nil) throws -> ChatSessionController {
        let resolvedSettings: SettingsManager
        if let settings {
            resolvedSettings = settings
        } else {
            resolvedSettings = SettingsManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)")))
        }

        return ChatSessionController(
            dataStore: try makeDiscoveryInMemoryStore(),
            settingsManager: resolvedSettings
        )
    }

    private static func sampleSnippet() -> TextExpansionSnippet {
        TextExpansionSnippet(
            title: "Support reply",
            trigger: "support",
            body: "Thanks for the context. I will follow up with the next step.",
            mode: .llmRewrite
        )
    }
}
