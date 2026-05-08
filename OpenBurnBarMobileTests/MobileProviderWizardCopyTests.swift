import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

/// Proves the iOS provider wizard reads its credential copy, dashboard URLs,
/// validation hints, and capability chips from `BurnBarProviderAuthRegistry`
/// (the cross-platform source of truth) rather than only from the iOS-side
/// hand-coded `ProviderSetupGuide`. Without this bridge, iOS would drift
/// from the macOS wizard whenever new providers/methods are added.
final class MobileProviderWizardCopyTests: XCTestCase {

    // MARK: - Registry → Guide enrichment

    func test_zaiGuide_pullsPlaceholderAndFooterFromRegistry() {
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: .zai)
        let descriptor = ProviderSetupGuide.registryDescriptor(for: .zai)
        XCTAssertNotNil(descriptor, "Z.ai must have a registry descriptor.")

        let primary = descriptor!.primaryMethod
        XCTAssertEqual(guide.credentialPlaceholder, primary.placeholder,
                       "Z.ai placeholder must come from BurnBarProviderAuthRegistry.")
        XCTAssertTrue(guide.credentialFooterMarkdown.contains(primary.helperText),
                      "Z.ai footer must include registry helper text.")
        if let urlString = primary.dashboardURL {
            XCTAssertEqual(guide.dashboardURL, URL(string: urlString),
                           "Z.ai dashboard URL must come from registry.")
        }
    }

    func test_minimaxGuide_pullsCopyFromRegistry() {
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: .minimax)
        let descriptor = ProviderSetupGuide.registryDescriptor(for: .minimax)
        XCTAssertNotNil(descriptor, "MiniMax must have a registry descriptor.")

        XCTAssertGreaterThan(descriptor!.methods.count, 1,
                             "MiniMax must advertise multiple credential methods (Token Plan + Coding Plan).")

        let primary = descriptor!.primaryMethod
        XCTAssertEqual(guide.credentialPlaceholder, primary.placeholder,
                       "MiniMax placeholder must come from registry.")
    }

    func test_kimiGuide_resolvesViaMoonshotAlias() {
        // The catalog uses "moonshot" but the AgentProvider is .kimi. The
        // bridge must walk both candidate IDs.
        let descriptor = ProviderSetupGuide.registryDescriptor(for: .kimi)
        XCTAssertNotNil(descriptor, "Kimi must resolve through the moonshot alias.")
        XCTAssertTrue(descriptor!.aliasProviderIDs.contains("kimi") || descriptor!.providerID == "moonshot",
                      "Kimi descriptor must alias both kimi and moonshot.")
    }

    func test_openAIGuide_pullsCopyFromRegistry() {
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: .openAI)
        let descriptor = ProviderSetupGuide.registryDescriptor(for: .openAI)
        XCTAssertNotNil(descriptor, "OpenAI must have a registry descriptor.")

        let primary = descriptor!.primaryMethod
        XCTAssertEqual(guide.credentialPlaceholder, primary.placeholder)
        XCTAssertFalse(guide.credentialFooterMarkdown.isEmpty,
                       "OpenAI footer must be non-empty after registry enrichment.")
    }

    // MARK: - Hand-coded guide preservation

    func test_registryEnrichment_preservesNumberedInstructions() {
        for provider in [AgentProvider.zai, .minimax, .openAI, .claudeCode, .codex, .cursor] {
            let base = ProviderSetupGuide.guide(for: provider)
            let enriched = ProviderSetupGuide.registryEnrichedGuide(for: provider)
            XCTAssertEqual(enriched.instructions.map(\.number), base.instructions.map(\.number),
                           "Registry enrichment must preserve numbered instructions for \(provider.displayName).")
            XCTAssertEqual(enriched.instructions.map(\.title), base.instructions.map(\.title),
                           "Registry enrichment must not alter instruction titles for \(provider.displayName).")
        }
    }

    func test_providersWithoutRegistryDescriptor_fallBackToHandCodedGuide() {
        // Cursor isn't in the registry — its guide should be unchanged after enrichment.
        let base = ProviderSetupGuide.guide(for: .cursor)
        let enriched = ProviderSetupGuide.registryEnrichedGuide(for: .cursor)
        XCTAssertEqual(base.credentialPlaceholder, enriched.credentialPlaceholder)
        XCTAssertEqual(base.dashboardCTA, enriched.dashboardCTA)
        XCTAssertEqual(base.dashboardURL, enriched.dashboardURL)
    }

    // MARK: - Validation bridging

    func test_registryValidation_emptyCredentialIsEmpty() {
        XCTAssertEqual(ProviderSetupGuide.registryValidation(credential: "", for: .zai), .empty)
    }

    func test_registryValidation_zaiWarningOnTooShort() {
        let result = ProviderSetupGuide.registryValidation(credential: "abc", for: .zai)
        XCTAssertTrue(result.isWarning, "Short Z.ai credential must surface a warning.")
    }

    func test_registryValidation_validBearerPassesForOpenAI() {
        let credential = "sk-proj-" + String(repeating: "x", count: 32)
        let result = ProviderSetupGuide.registryValidation(credential: credential, for: .openAI)
        XCTAssertTrue(result.isOK, "Well-formed OpenAI key should validate cleanly.")
    }

    func test_registryValidation_unmappedProviderUsesLengthHeuristic() {
        // Cursor isn't in the registry so should fall through to the length
        // heuristic. Anything < 8 chars is a warning, longer is OK.
        let short = ProviderSetupGuide.registryValidation(credential: "abc", for: .cursor)
        XCTAssertTrue(short.isWarning, "Short cursor cookie must warn even without registry descriptor.")

        let longCookie = "WorkosCursorSessionToken=" + String(repeating: "a", count: 32)
        let okay = ProviderSetupGuide.registryValidation(credential: longCookie, for: .cursor)
        XCTAssertTrue(okay.isOK, "Long cursor cookie should validate.")
    }

    // MARK: - Capability chips

    func test_capabilityChips_reflectRegistryFlags() {
        let zaiChips = ProviderSetupGuide.capabilityChips(for: .zai)
        XCTAssertTrue(zaiChips.contains("Routes on Mac"),
                      "Z.ai should advertise routing capability on Mac.")
        XCTAssertTrue(zaiChips.contains("Live quota"),
                      "Z.ai should advertise live quota refresh.")
    }

    func test_capabilityChips_emptyForUnmappedProvider() {
        // Cursor isn't in the registry so chips should be empty.
        XCTAssertTrue(ProviderSetupGuide.capabilityChips(for: .cursor).isEmpty)
    }

    // MARK: - Mask helper

    func test_maskCredential_keepsFirstAndLastFourCharacters() {
        let masked = mobileMaskCredential("sk-proj-abcdef1234567890")
        XCTAssertTrue(masked.hasPrefix("sk-p"))
        XCTAssertTrue(masked.hasSuffix("7890"))
        XCTAssertTrue(masked.contains("•"))
    }

    func test_maskCredential_emptyReturnsEmpty() {
        XCTAssertEqual(mobileMaskCredential(""), "")
        XCTAssertEqual(mobileMaskCredential("   "), "")
    }
}
