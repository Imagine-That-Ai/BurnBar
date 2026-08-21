import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Pins the context window the gateway advertises in its Codex-compatible
/// `/v1/models` payload.
///
/// Codex clients read `context_window` / `truncation_policy.limit` to decide when
/// to truncate and compact, so an over-advertised window is not a cosmetic bug:
/// the conversation grows past the upstream limit and the request fails instead
/// of compacting. A regression here therefore has to be a *conservative* one —
/// these tests assert that an unknown limit stays at the small fallback and that
/// the model's NAME never talks us into a bigger number.
final class GatewayAdvertisedContextWindowTests: XCTestCase {
    private typealias Descriptor = BurnBarHTTPGatewayServer.CodexModelDescriptor

    private let openaiCompat = BurnBarProviderFormatFamily.openaiCompat.rawValue
    private let anthropic = BurnBarProviderFormatFamily.anthropic.rawValue

    private func advertised(
        _ modelID: String,
        family: String? = nil,
        declared: Int? = nil
    ) -> Int {
        Descriptor.advertisedContextWindow(
            formatFamily: family ?? openaiCompat,
            modelID: modelID,
            declaredContextWindowTokens: declared
        )
    }

    // MARK: - A reported limit is the only limit we trust

    func testDiscoveredContextWindowIsAdvertisedVerbatim() {
        XCTAssertEqual(advertised("gpt-5.6-terra", declared: 400_000), 400_000)
        XCTAssertEqual(advertised("some-local-build", declared: 8_192), 8_192)
        XCTAssertEqual(
            advertised("claude-sonnet-4-6", family: anthropic, declared: 500_000),
            500_000
        )
    }

    /// `ModelIOCapabilities.init` drops non-positive windows, but a decoded
    /// capability payload bypasses that init. A zero must not become a
    /// zero-token truncation policy.
    func testNonPositiveDeclaredContextWindowFallsBackInsteadOfAdvertisingZero() {
        XCTAssertEqual(
            advertised("weird-upstream", declared: 0),
            Descriptor.unknownContextWindowFallback
        )
        XCTAssertEqual(
            advertised("weird-upstream", declared: -1),
            Descriptor.unknownContextWindowFallback
        )
    }

    // MARK: - Unknown limits stay conservative

    /// The regression this file exists for: names containing `gpt`, `codex`,
    /// `luna`, `sol`, or `terra` were briefly advertised as one-million-token
    /// routes regardless of the real upstream limit.
    func testUnknownContextWindowIsNeverInflatedByTheModelName() {
        let namesThatOnceMatchedTheInflatedGuess = [
            "gpt-4",
            "gpt-4-0613",
            "gpt-5.6-luna",
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "codex-mini-latest",
            // The `sol`/`terra` substrings also swept up unrelated vendors.
            "solar-pro-preview",
            "mistral-console-terra",
            "qwen3-coder-consolidated"
        ]

        for name in namesThatOnceMatchedTheInflatedGuess {
            XCTAssertEqual(
                advertised(name),
                Descriptor.unknownContextWindowFallback,
                "\(name) has no reported window, so it must not be advertised as anything larger than the fallback"
            )
        }
    }

    func testUnknownContextWindowFallbackIsSmallEnoughToForceCompaction() {
        // Below the smallest window any routable frontier model ships with, so a
        // client that trusts it compacts early rather than failing upstream.
        XCTAssertLessThanOrEqual(Descriptor.unknownContextWindowFallback, 128_000)
        XCTAssertGreaterThan(Descriptor.unknownContextWindowFallback, 0)
        XCTAssertEqual(advertised("totally-unknown-custom-route"), 65_536)
    }

    func testModelNameMatchingIsCaseInsensitiveOnlyWhereItStillApplies() {
        XCTAssertEqual(advertised("GPT-5.6-TERRA"), Descriptor.unknownContextWindowFallback)
        XCTAssertEqual(advertised("Claude-OPUS-4-5", family: anthropic), 1_000_000)
    }

    // MARK: - Published Anthropic windows survive

    func testAnthropicFamilyKeepsItsPublishedWindows() {
        XCTAssertEqual(advertised("claude-sonnet-4-6", family: anthropic), 200_000)
        XCTAssertEqual(advertised("claude-haiku-4-5", family: anthropic), 200_000)
        XCTAssertEqual(advertised("claude-opus-4-5", family: anthropic), 1_000_000)
    }

    /// `opus` is only meaningful inside the Anthropic family — an
    /// OpenAI-compatible route that happens to be named after it gets no
    /// special treatment.
    func testOpusNameOutsideAnthropicFamilyDoesNotInheritTheAnthropicWindow() {
        XCTAssertEqual(advertised("opus-clone-7b"), Descriptor.unknownContextWindowFallback)
    }

    // MARK: - The descriptor wires the policy through

    func testTruncationPolicyLimitMatchesTheAdvertisedContextWindow() throws {
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                Descriptor(model: makeModelDescriptor(id: "gpt-5.6-terra"))
            )
        )
        let object = try XCTUnwrap(json as? [String: Any])
        let policy = try XCTUnwrap(object["truncation_policy"] as? [String: Any])

        XCTAssertEqual(object["context_window"] as? Int, Descriptor.unknownContextWindowFallback)
        XCTAssertEqual(object["max_context_window"] as? Int, Descriptor.unknownContextWindowFallback)
        XCTAssertEqual(policy["limit"] as? Int, Descriptor.unknownContextWindowFallback)
    }

    private func makeModelDescriptor(id: String) -> BurnBarHTTPGatewayServer.ModelDescriptor {
        let model = BurnBarLiveAdvertisedModel(
            id: id,
            displayName: id,
            providerID: "openai",
            providerName: "OpenAI",
            accountID: "account-1",
            accountLabel: "Account 1",
            sourceID: "source-1",
            sourceKind: "live",
            capabilities: [],
            quotaState: .healthy,
            enabled: true,
            routeEligible: true
        )
        return BurnBarHTTPGatewayServer.ModelDescriptor(
            group: BurnBarHTTPGatewayServer.GatewayModelCatalogGroup(
                providerID: "openai",
                normalizedModelID: id,
                entries: [.init(model: model, advertised: true)]
            ),
            advertisedID: id
        )
    }
}
