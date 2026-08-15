import Foundation

// MARK: - Usage Memory Model Router (U5)
//
// PURE routing table for the usage-memory curation pipeline: given a settings /
// availability snapshot and whether the batch carries image content, decide
// which model lane serves the batch. No I/O, no Firebase, no settings reads —
// the caller (PR6's pipeline) builds the `Snapshot` on the MainActor and the
// router stays table-testable in isolation.
//
// Fail-safe posture: every ambiguous or under-provisioned combination degrades
// toward `.queueOnly` (candidates stay queued, nothing is sent anywhere), never
// toward an unintended cloud call.
enum UsageMemoryModelRouter {

    /// Immutable input to one routing decision. Built by the caller from
    /// `SettingsManager` gates (U1), local model configuration, the client-side
    /// daily budget ledger, and the last-known server allowance state (U4).
    struct Snapshot: Equatable, Sendable {
        /// Where the user pointed curation (`.local` default).
        var placement: UsageMemoryModelPlacement
        /// Combined `usageMemoryExtractionEnabled` gate (consent AND fleet switch).
        var extractionEnabled: Bool
        /// Combined `usageMemoryCloudCurationEnabled` gate (extraction AND cloud
        /// consent AND cloud placement).
        var cloudCurationEnabled: Bool
        /// A local text model is configured/reachable (e.g. `summaryLocalModel`).
        var localTextModelAvailable: Bool
        /// A local vision-language model is configured (`usageMemoryLocalVLModel`
        /// non-empty). Empty string = images are skipped locally.
        var localVLModelAvailable: Bool
        /// Client belt-and-braces daily USD cap has headroom
        /// (`UsageMemoryBudgetLedger.cloudBudgetOK`).
        var cloudBudgetOK: Bool
        /// Server reported the TEXT lane's allowance exhausted
        /// (`resource-exhausted` with lane "text", not yet past `resetsAt`).
        var serverTextExhausted: Bool
        /// Server reported the MULTIMODAL lane's allowance exhausted.
        var serverMultimodalExhausted: Bool
    }

    /// Where one batch goes. `queueOnly` = keep the candidates queued and send
    /// nothing anywhere (dormant, unconfigured, or fully exhausted).
    enum Route: Equatable, Sendable {
        /// BurnBar cloud, multimodal lane (`curateUsageMemoryBatch`, lane "multimodal").
        case burnbarCloudMultimodal
        /// BurnBar cloud, text lane (`curateUsageMemoryBatch`, lane "text";
        /// any image content is stripped before send).
        case burnbarCloudText
        /// Local text model; any image content is stripped.
        case localText
        /// Local vision-language model with images attached.
        case localMultimodal
        /// No model available/allowed — candidates stay queued.
        case queueOnly
    }

    /// The routing table.
    ///
    /// - `extractionEnabled == false` ⇒ `.queueOnly`. Callers should never reach
    ///   the router while the feature is dormant, but the router fails safe.
    /// - `.local` placement ⇒ local lanes only: `.localMultimodal` when the batch
    ///   has images AND a local VL model exists; otherwise `.localText` (images
    ///   stripped) when a local text model exists; otherwise `.queueOnly`.
    /// - Cloud placements require the cloud gate AND client budget headroom;
    ///   when either is missing they fall back to the local chain above.
    /// - `.burnbarCloud` with images prefers the multimodal lane while the server
    ///   allowance lasts; a multimodal exhaustion degrades to the text lane
    ///   (images stripped) while text allowance lasts, then to the local chain.
    /// - `.cloudText` (and `.burnbarCloud` without images) uses the text lane
    ///   while text allowance lasts, then the local chain.
    static func route(snapshot: Snapshot, hasImageContent: Bool) -> Route {
        guard snapshot.extractionEnabled else { return .queueOnly }

        switch snapshot.placement {
        case .local:
            return localRoute(snapshot, hasImageContent: hasImageContent)

        case .cloudText, .burnbarCloud:
            guard snapshot.cloudCurationEnabled, snapshot.cloudBudgetOK else {
                return localRoute(snapshot, hasImageContent: hasImageContent)
            }
            if snapshot.placement == .burnbarCloud,
               hasImageContent,
               snapshot.serverMultimodalExhausted == false {
                return .burnbarCloudMultimodal
            }
            if snapshot.serverTextExhausted == false {
                return .burnbarCloudText
            }
            return localRoute(snapshot, hasImageContent: hasImageContent)
        }
    }

    /// The local chain (also the fallback tail of every cloud route): VL model
    /// for image batches, else text model with images stripped, else queue.
    private static func localRoute(_ snapshot: Snapshot, hasImageContent: Bool) -> Route {
        if hasImageContent, snapshot.localVLModelAvailable {
            return .localMultimodal
        }
        if snapshot.localTextModelAvailable {
            return .localText
        }
        return .queueOnly
    }
}
