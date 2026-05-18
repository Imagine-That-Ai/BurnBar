import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class AssistantModelMergerTests: XCTestCase {

    // MARK: - Self-loop guard

    func test_dropsHermesSelfLoopFromLiveRelay() {
        let live = [
            opt("hermes-agent", provider: "hermes"),
            opt("claude-opus-4-7", provider: "anthropic"),
        ]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: live,
            catalog: [],
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.map(\.option.modelID), ["claude-opus-4-7"])
        XCTAssertEqual(rows.first?.reachability, .liveOnRelay)
    }

    func test_dropsPiSelfLoopFromLiveRelay() {
        let live = [
            opt("pi-agent", provider: "pi"),
            opt("pi", provider: "pi"),
            opt("kimi-k2-6", provider: "kimi"),
        ]
        let rows = AssistantModelMerger.merge(
            runtime: .pi,
            liveRelay: live,
            catalog: [],
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.map(\.option.modelID), ["kimi-k2-6"])
    }

    func test_dropsOpenClawSelfLoop() {
        let live = [
            opt("openclaw", provider: "openclaw"),
            opt("qwen3-coder:30b", provider: "ollama"),
        ]
        let rows = AssistantModelMerger.merge(
            runtime: .openClaw,
            liveRelay: live,
            catalog: [],
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.map(\.option.modelID), ["qwen3-coder:30b"])
    }

    func test_preservesModelIDsThatJustStartWithHarnessToken() {
        // `hermes-mini` is a hypothetical real model — the guard must be
        // an exact match on the placeholder token, not a prefix strip.
        let live = [
            cat("hermes-mini", provider: "hermes"),
        ]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: live.map(asLive),
            catalog: live,
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.map(\.option.modelID), ["hermes-mini"])
        XCTAssertEqual(rows.first?.reachability, .liveOnRelay)
    }

    // MARK: - Live wins, catalog enriches

    func test_liveWinsOnConflict() {
        // Live says "claude-opus-4-7" exists with a custom display name.
        // Catalog also lists it. The merged row should keep catalog's
        // curated display name (the live one is often just the modelID)
        // but be tagged `.liveOnRelay`.
        let live = [HermesRuntimeModelOption(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-opus-4-7",
            displayName: "claude-opus-4-7"
        )]
        let catalog = [AssistantModelOption(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-opus-4-7",
            displayName: "Claude Opus 4.7",
            tier: "flagship"
        )]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: live,
            catalog: catalog,
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].option.displayName, "Claude Opus 4.7")
        XCTAssertEqual(rows[0].reachability, .liveOnRelay)
    }

    func test_liveAliasWinsAndUsesExactRelayModelID() {
        let live = [HermesRuntimeModelOption(
            providerID: "minimax",
            providerName: "MiniMax",
            modelID: "MiniMax-M2.7",
            displayName: "MiniMax M2.7"
        )]
        let catalog = [AssistantModelOption(
            providerID: "minimax",
            providerName: "MiniMax",
            modelID: "minimax-m2-7",
            displayName: "MiniMax M2.7",
            tier: "flagship"
        )]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: live,
            catalog: catalog,
            connectedProviderIDs: []
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].option.modelID, "MiniMax-M2.7")
        XCTAssertEqual(rows[0].reachability, .liveOnRelay)
    }

    func test_liveOnlyModelsAppendedAfterCatalog() {
        // Relay advertises a model the catalog hasn't seen yet — trust
        // the relay and append at the end.
        let live = [opt("brand-new-llm", provider: "openai")]
        let catalog = [cat("claude-opus-4-7", provider: "anthropic")]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: live,
            catalog: catalog,
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.map(\.option.modelID), ["claude-opus-4-7", "brand-new-llm"])
        XCTAssertEqual(rows.last?.reachability, .liveOnRelay)
    }

    // MARK: - Connected-on-iOS tagging

    func test_connectedProviderTagged() {
        // No live data; catalog has an Anthropic row; user has Anthropic
        // connected. Row should be `.connectedOnIOS` when relay data is
        // loaded and live models exist (even if none match this catalog row).
        let catalog = [cat("claude-opus-4-7", provider: "anthropic")]
        let liveRelay = [opt("minimax-m2.7-highspeed", provider: "minimax")]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: liveRelay,
            catalog: catalog,
            connectedProviderIDs: [.anthropic]
        )
        XCTAssertEqual(rows.first?.reachability, .connectedOnIOS)
    }

    func test_connectedProviderTaggedPendingWhenRelayDataAbsent() {
        // When relay data hasn't loaded yet (empty relay, refresh in
        // progress), connected providers should be marked
        // `.pendingRelayData` so the UI shows a loading hint instead
        // of misleading "Not live" / "Relay only".
        let catalog = [cat("claude-opus-4-7", provider: "anthropic")]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: catalog,
            connectedProviderIDs: [.anthropic],
            relayDataLoaded: false
        )
        XCTAssertEqual(rows.first?.reachability, .pendingRelayData)
    }

    func test_connectedProviderTaggedPendingWhenRelayEmptyButStillLoading() {
        // Even with relayDataLoaded=true, if liveRelay is genuinely empty
        // (relay returned no models), connected providers get
        // `.pendingRelayData` because we can't distinguish "relay has
        // no models" from "relay data hasn't arrived yet" without the
        // relayDataLoaded flag being false.
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: [cat("claude-opus-4-7", provider: "anthropic")],
            connectedProviderIDs: [.anthropic],
            relayDataLoaded: true
        )
        // Empty relay with relayDataLoaded=true means relay genuinely
        // returned no models — connected provider is correctly
        // `.connectedOnIOS` (relay confirmed it doesn't advertise).
        // But if relayDataLoaded is false, it's pending.
        XCTAssertEqual(rows.first?.reachability, .connectedOnIOS)

        let rowsPending = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: [cat("claude-opus-4-7", provider: "anthropic")],
            connectedProviderIDs: [.anthropic],
            relayDataLoaded: false
        )
        XCTAssertEqual(rowsPending.first?.reachability, .pendingRelayData)
    }

    func test_unreachableWhenNoLiveNoAccount() {
        let catalog = [cat("kimi-k2-6", provider: "kimi")]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: catalog,
            connectedProviderIDs: [.anthropic] // different provider
        )
        XCTAssertEqual(rows.first?.reachability, .unreachable)
    }

    func test_unreachableEvenWhenRelayDataPending() {
        // Providers without a connected account are always unreachable,
        // regardless of relay data loading state.
        let catalog = [cat("kimi-k2-6", provider: "kimi")]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: catalog,
            connectedProviderIDs: [.anthropic],
            relayDataLoaded: false
        )
        XCTAssertEqual(rows.first?.reachability, .unreachable)
    }

    // MARK: - Order preservation

    func test_catalogOrderPreserved() {
        let catalog = [
            cat("claude-opus-4-7", provider: "anthropic"),
            cat("gpt-5-5", provider: "openai"),
            cat("kimi-k2-6", provider: "kimi"),
        ]
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: catalog,
            connectedProviderIDs: []
        )
        XCTAssertEqual(rows.map(\.option.modelID),
                       ["claude-opus-4-7", "gpt-5-5", "kimi-k2-6"])
    }

    // MARK: - Empty fallback

    func test_emptyLiveAndCatalogYieldsEmptyRows() {
        let rows = AssistantModelMerger.merge(
            runtime: .hermes,
            liveRelay: [],
            catalog: [],
            connectedProviderIDs: []
        )
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Helpers

    private func opt(_ modelID: String, provider: String) -> HermesRuntimeModelOption {
        HermesRuntimeModelOption(
            providerID: provider,
            providerName: provider.capitalized,
            modelID: modelID,
            displayName: modelID
        )
    }

    private func cat(_ modelID: String, provider: String) -> AssistantModelOption {
        AssistantModelOption(
            providerID: provider,
            providerName: provider.capitalized,
            modelID: modelID,
            displayName: modelID,
            tier: "mid"
        )
    }

    private func asLive(_ option: AssistantModelOption) -> HermesRuntimeModelOption {
        HermesRuntimeModelOption(
            providerID: option.providerID,
            providerName: option.providerName,
            modelID: option.modelID,
            displayName: option.displayName
        )
    }
}
