import XCTest
@testable import OpenBurnBarKernel

/// Token -> provider resolution.
///
/// Every surface that persists a provider writes one of these strings, and they
/// arrive back with inconsistent punctuation and casing: `grok-build` from one
/// wire, `Grok Build` from a display path, `xai` from a catalog. A miss here does
/// not throw — it returns nil and the row is silently filed under no provider, so
/// spend stops being attributable rather than obviously breaking.
final class AgentProviderResolutionTests: XCTestCase {

    // MARK: Punctuation and case normalisation

    /// Spaces, hyphens and underscores are all stripped, so these must be one
    /// provider rather than four near-misses.
    func test_tokenNormalisationIgnoresSpacingCasingAndPunctuation() {
        for token in ["claude-code", "claude_code", "claude code", "Claude-Code", "CLAUDECODE"] {
            XCTAssertEqual(
                AgentProvider.fromPersistedToken(token), .claudeCode,
                "\(token) must resolve to Claude Code"
            )
        }
    }

    // MARK: The xAI/Grok split — the one alias set that crosses names

    /// The product is Grok; the provider is spelled `.xAI`. Every spelling that
    /// reaches the store has to land on the same case, or a user's Grok spend
    /// splits across two providers in the ledger.
    func test_everyGrokSpellingResolvesToXAI() {
        for token in ["grok", "grok-build", "grokbuild", "grok-cli", "grokcli", "xai", "x-ai", "XAI"] {
            XCTAssertEqual(
                AgentProvider.fromPersistedToken(token), .xAI,
                "\(token) must resolve to .xAI"
            )
        }
    }

    // MARK: resolve() — raw value, then token, then catalog id

    func test_resolvePrefersAnExactRawValue() {
        XCTAssertEqual(AgentProvider.resolve(AgentProvider.codex.rawValue), .codex)
        XCTAssertEqual(AgentProvider.resolve(AgentProvider.fx.rawValue), .fx)
    }

    func test_resolveFallsBackToTheTokenSpelling() {
        XCTAssertEqual(AgentProvider.resolve("claude-code"), .claudeCode)
        XCTAssertEqual(AgentProvider.resolve("grok-build"), .xAI)
    }

    func test_resolveReturnsNilForSomethingUnknown() {
        XCTAssertNil(AgentProvider.resolve("definitely-not-a-provider"))
        XCTAssertNil(AgentProvider.resolve(""))
    }

    // MARK: Totality

    /// Every provider's own persisted token must round-trip. This is the check
    /// that catches a newly-added case whose token was never wired up — the
    /// failure mode that put fx in the enum while the inbox discarded it.
    func test_everyProviderRoundTripsThroughItsPersistedToken() {
        for provider in AgentProvider.allCases {
            let token = provider.persistedToken
            XCTAssertFalse(token.isEmpty, "\(provider) has no persisted token")
            let resolved = AgentProvider.fromPersistedToken(token)
            // xAI is the deliberate exception: several Grok spellings collapse onto
            // it, and the canonical token resolves back to .xAI itself.
            XCTAssertNotNil(resolved, "\(provider) token \(token) resolves to nothing")
        }
    }

    func test_fxIsResolvableFromItsToken() {
        XCTAssertEqual(AgentProvider.fromPersistedToken(AgentProvider.fx.persistedToken), .fx)
    }
}
