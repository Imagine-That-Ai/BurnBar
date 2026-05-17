@testable import OpenBurnBar
import OpenBurnBarCore
import XCTest

/// Pins the asset-name lookup for every provider the local OpenBurnBar
/// gateway can advertise. The Agents → Models drill must show the right
/// logo for every provider, including the ones with no `AgentProvider`
/// case (DeepSeek, Mistral, xAI, Meta, Cohere, Amazon, Alibaba, MLX).
@MainActor
final class ProxyProviderLogoResolutionTests: XCTestCase {

    // MARK: - DeepSeek

    func test_assetCandidates_deepSeekIncludesProviderLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "deepseek")
        XCTAssertTrue(names.contains("DeepSeekProviderLogo"))
        XCTAssertTrue(names.contains("DeepSeekLogo"))
    }

    func test_assetCandidates_deepSeekAliasMaps() {
        let names = ProxyProviderLogoView.assetCandidates(for: "deep-seek")
        XCTAssertTrue(names.contains("DeepSeekProviderLogo"))
    }

    // MARK: - xAI / Grok

    func test_assetCandidates_xaiResolvesToGrok() {
        let names = ProxyProviderLogoView.assetCandidates(for: "xai")
        XCTAssertTrue(names.contains("GrokLogo"))
    }

    func test_assetCandidates_grokAlsoResolvesToGrok() {
        let names = ProxyProviderLogoView.assetCandidates(for: "grok")
        XCTAssertTrue(names.contains("GrokLogo"))
    }

    // MARK: - Mistral, Meta, Cohere, Amazon, Alibaba, MLX

    func test_assetCandidates_mistralIncludesProviderLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "mistral")
        XCTAssertTrue(names.contains("MistralProviderLogo"))
        XCTAssertTrue(names.contains("MistralLogo"))
    }

    func test_assetCandidates_metaIncludesProviderLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "meta")
        XCTAssertTrue(names.contains("MetaProviderLogo"))
        XCTAssertTrue(names.contains("MetaLogo"))
    }

    func test_assetCandidates_llamaResolvesToMeta() {
        let names = ProxyProviderLogoView.assetCandidates(for: "llama")
        XCTAssertTrue(names.contains("MetaProviderLogo"))
    }

    func test_assetCandidates_cohereIncludesProviderLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "cohere")
        XCTAssertTrue(names.contains("CohereProviderLogo"))
        XCTAssertTrue(names.contains("CohereLogo"))
    }

    func test_assetCandidates_amazonIncludesProviderLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "amazon")
        XCTAssertTrue(names.contains("AmazonProviderLogo"))
    }

    func test_assetCandidates_bedrockAliasMaps() {
        let names = ProxyProviderLogoView.assetCandidates(for: "bedrock")
        XCTAssertTrue(names.contains("AmazonProviderLogo"))
    }

    func test_assetCandidates_alibabaIncludesProviderLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "alibaba")
        XCTAssertTrue(names.contains("AlibabaProviderLogo"))
        XCTAssertTrue(names.contains("QwenLogo"))
    }

    func test_assetCandidates_qwenAliasMaps() {
        let names = ProxyProviderLogoView.assetCandidates(for: "qwen")
        XCTAssertTrue(names.contains("AlibabaProviderLogo"))
        XCTAssertTrue(names.contains("QwenLogo"))
    }

    func test_assetCandidates_mlxIncludesMLXLogo() {
        let names = ProxyProviderLogoView.assetCandidates(for: "mlx")
        XCTAssertTrue(names.contains("MLXLogo"))
    }

    // MARK: - Canonical providers still resolve

    func test_assetCandidates_anthropicResolves() {
        let names = ProxyProviderLogoView.assetCandidates(for: "anthropic")
        XCTAssertTrue(names.contains("AnthropicLogo"))
        XCTAssertTrue(names.contains("ClaudeCodeLogo"))
    }

    func test_assetCandidates_openAIResolves() {
        let names = ProxyProviderLogoView.assetCandidates(for: "openai")
        XCTAssertTrue(names.contains("OpenAILogo"))
    }

    func test_assetCandidates_googleResolves() {
        let names = ProxyProviderLogoView.assetCandidates(for: "google")
        XCTAssertTrue(names.contains("GoogleLogo"))
    }

    func test_assetCandidates_moonshotResolvesKimi() {
        let names = ProxyProviderLogoView.assetCandidates(for: "moonshot")
        XCTAssertTrue(names.contains("KimiProviderLogo"))
        XCTAssertTrue(names.contains("KimiLogo"))
    }

    // MARK: - Unknown provider falls back to convention

    func test_assetCandidates_unknownProviderFallsBackToConvention() {
        let names = ProxyProviderLogoView.assetCandidates(for: "futurelab")
        XCTAssertTrue(names.contains("FuturelabLogo"))
    }

    // MARK: - Deduplication

    func test_assetCandidates_dedupesRepeatedNames() {
        let names = ProxyProviderLogoView.assetCandidates(for: "deepseek")
        XCTAssertEqual(names.count, Set(names).count, "Asset candidate list should be deduplicated")
    }

    // MARK: - Monogram fallback

    func test_monogramText_usesFirstLetterOfSingleWord() {
        XCTAssertEqual(
            ProxyProviderLogoView.monogramText(for: "Acme", fallbackID: "acme"),
            "A"
        )
    }

    func test_monogramText_combinesFirstTwoInitials() {
        XCTAssertEqual(
            ProxyProviderLogoView.monogramText(for: "Future Lab AI", fallbackID: "futurelab"),
            "FL"
        )
    }

    func test_monogramText_handlesPunctuation() {
        XCTAssertEqual(
            ProxyProviderLogoView.monogramText(for: "future.lab", fallbackID: "future.lab"),
            "FL"
        )
    }

    func test_monogramText_emptyNameFallsBackToID() {
        XCTAssertEqual(
            ProxyProviderLogoView.monogramText(for: "  ", fallbackID: "futurelab"),
            "F"
        )
    }

    func test_monogramText_bothEmptyReturnsQuestionMark() {
        XCTAssertEqual(
            ProxyProviderLogoView.monogramText(for: "", fallbackID: ""),
            "?"
        )
    }
}
