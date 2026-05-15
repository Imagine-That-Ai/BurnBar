import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Provider Bridge Tests
//
// Locks the AgentIdentity → AgentProvider mapping so a future enum
// reorder doesn't silently swap which logo renders for which runtime.

final class HermesSquareProviderBridgeTests: XCTestCase {

    func testBuiltInRuntimesResolveToTheirCanonicalProviders() {
        let cases: [(AssistantRuntimeID, AgentProvider)] = [
            (.hermes,   .hermes),
            (.pi,       .piAgent),
            (.claude,   .claudeCode),
            (.codex,    .codex),
            (.openClaw, .openClaw)
        ]
        for (runtime, expectedProvider) in cases {
            let identity = AgentIdentity.builtIn(runtime)
            XCTAssertEqual(
                identity.resolvedProvider,
                expectedProvider,
                "\(runtime.rawValue) should map to \(expectedProvider.rawValue)"
            )
        }
    }

    func testUnknownThirdPartyURIResolvesToNil() {
        let identity = AgentIdentity(
            id: "agent://third-party/unknown-vendor/scout",
            displayName: "Scout",
            glyph: "🔭",
            paletteHex: "00A67E"
        )
        XCTAssertNil(identity.resolvedProvider,
                     "Unknown vendor token must NOT resolve to a provider")
    }

    func testKnownThirdPartyVendorResolves() {
        // Use a vendor token that exists in the AgentProvider catalog
        // (`cursor` is a known persisted token).
        let identity = AgentIdentity(
            id: "agent://third-party/cursor/inline-edit",
            displayName: "Cursor Inline",
            glyph: "✦",
            paletteHex: "AC8C57"
        )
        XCTAssertEqual(identity.resolvedProvider, .cursor)
    }

    func testBuiltInProviderHelperIsExhaustive() {
        // Compile-time exhaustiveness check via switch: every case must
        // map. If a new AssistantRuntimeID is added, the project won't
        // compile without updating `builtInProvider(for:)`.
        for runtime in AssistantRuntimeID.allCases {
            let provider = AgentIdentity.builtInProvider(for: runtime)
            XCTAssertFalse(provider.rawValue.isEmpty,
                           "Missing provider for runtime \(runtime.rawValue)")
        }
    }
}
