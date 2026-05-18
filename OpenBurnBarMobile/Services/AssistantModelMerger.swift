import Foundation
import OpenBurnBarCore

// MARK: - Assistant Model Merger
//
// Folds three sources into one ordered, reachability-tagged list:
//   1. Live relay (HermesService.modelOptions / PiService.modelOptions /
//      OpenClawService.modelOptions) — the user's *own* relay's truthful
//      "this is what I can route to right now" list.
//   2. User's connected provider accounts (AccountStore.connectedProviderIDs)
//      — providers the user has wired up on iOS even if the relay hasn't
//      enumerated them yet.
//   3. Static / remote catalog (AssistantModelCatalog) — the global map of
//      what *could* exist. Used to fill in displayable rows when live and
//      account sources are silent.
//
// The picker calls `merge(...)` and renders the returned `Row`s grouped
// by provider. Each row carries a `reachability` tag the UI uses to
// style "Connect on iOS" CTAs vs. tappable model rows.
//
// This is the layer that resolves the broken "Hermes Agent / hermes-agent"
// self-loop: any live entry whose model id matches the harness itself is
// silently dropped before merging.

@MainActor
struct AssistantModelMerger {

    // MARK: Row

    struct Row: Identifiable, Hashable {
        let option: AssistantModelOption
        let reachability: Reachability

        var id: String { option.id }

        enum Reachability: Hashable {
            /// Relay's `/v1/models` returned this row right now. Most
            /// trustworthy — the user can route to it without further setup.
            case liveOnRelay
            /// Catalog row, no live coverage, but the user has the
            /// corresponding provider account connected on iOS. Likely
            /// reachable once a fresh relay session starts.
            case connectedOnIOS
            /// Catalog-only — neither relay nor account covers it. Picker
            /// dims this row and offers a "Connect" CTA.
            case unreachable
        }
    }

    // MARK: Public

    /// Build the merged row list for a runtime. Stable provider order
    /// follows the catalog; live-only rows (no catalog match) trail the
    /// catalog in their original relay order.
    static func merge(
        runtime: AssistantRuntimeID,
        liveRelay: [HermesRuntimeModelOption],
        catalog: [AssistantModelOption],
        connectedProviderIDs: Set<ProviderID>
    ) -> [Row] {
        let cleanLive = sanitize(liveRelay: liveRelay, runtime: runtime)
        let liveByModelID = cleanLive.reduce(into: [String: HermesRuntimeModelOption]()) { partialResult, live in
            partialResult[AssistantModelIDCanonicalizer.lookupKey(live.modelID)] = live
            partialResult[AssistantModelIDCanonicalizer.familyKey(live.modelID), default: live] = live
        }

        var rows: [Row] = []
        var consumedLiveIDs: Set<String> = []

        for catalogOption in catalog {
            let lookupKey = AssistantModelIDCanonicalizer.lookupKey(catalogOption.modelID)
            let familyKey = AssistantModelIDCanonicalizer.familyKey(catalogOption.modelID)
            if let live = liveByModelID[lookupKey] ?? liveByModelID[familyKey] {
                rows.append(Row(
                    option: enrich(catalog: catalogOption, with: live),
                    reachability: .liveOnRelay
                ))
                consumedLiveIDs.insert(live.modelID)
            } else if connectedProviderIDs.contains(catalogProviderID(catalogOption)) {
                rows.append(Row(option: catalogOption, reachability: .connectedOnIOS))
            } else {
                rows.append(Row(option: catalogOption, reachability: .unreachable))
            }
        }

        // Live rows that weren't in the catalog — trust the relay; the
        // catalog is just behind.
        for live in cleanLive where !consumedLiveIDs.contains(live.modelID) {
            rows.append(Row(
                option: AssistantModelOption(
                    providerID: live.providerID,
                    providerName: live.providerName,
                    modelID: live.modelID,
                    displayName: live.displayName,
                    tier: "mid"
                ),
                reachability: .liveOnRelay
            ))
        }

        return rows
    }

    // MARK: Self-loop guard

    /// Drop entries whose `modelID` is the harness's own name or persisted
    /// token (`hermes`, `hermes-agent`, `pi`, `pi-agent`, `openclaw`,
    /// `openclaw-agent`). Those are server-side placeholders, not real
    /// models the user can pick.
    static func sanitize(
        liveRelay: [HermesRuntimeModelOption],
        runtime: AssistantRuntimeID
    ) -> [HermesRuntimeModelOption] {
        let banned = bannedModelIDs(for: runtime)
        return liveRelay.filter { option in
            let normalized = option.modelID
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !banned.contains(normalized)
        }
    }

    private static func bannedModelIDs(for runtime: AssistantRuntimeID) -> Set<String> {
        switch runtime {
        case .hermes:
            return ["hermes", "hermes-agent", "hermes_agent"]
        case .pi:
            return ["pi", "pi-agent", "pi_agent", "piagent"]
        case .codex:
            return ["codex", "codex-agent"]
        case .claude:
            return ["claude", "claude-agent", "claude-code-agent"]
        case .openClaw:
            return ["openclaw", "openclaw-agent", "open-claw", "claw"]
        }
    }

    // MARK: Helpers

    /// Map a catalog row's `providerID` string (e.g. `"openai"`, `"zai"`)
    /// to the canonical `ProviderID` used by `AccountStore`.
    private static func catalogProviderID(_ option: AssistantModelOption) -> ProviderID {
        ProviderID(rawValue: option.providerID)
    }

    /// When live + catalog both describe the same model, keep the
    /// catalog's curated display name + tier but adopt the live entry's
    /// providerID/providerName so the picker tag stays consistent with
    /// what the relay actually reported.
    private static func enrich(
        catalog: AssistantModelOption,
        with live: HermesRuntimeModelOption
    ) -> AssistantModelOption {
        AssistantModelOption(
            providerID: catalog.providerID,
            providerName: catalog.providerName.isEmpty ? live.providerName : catalog.providerName,
            modelID: live.modelID,
            displayName: catalog.displayName.isEmpty ? live.displayName : catalog.displayName,
            tier: catalog.tier
        )
    }
}
