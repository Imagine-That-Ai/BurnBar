import Foundation
import OpenBurnBarCore

// MARK: - Quota domain (Core canonical types)
//
// Bucket/snapshot/source/confidence/unit/window kinds and plan-tier enums live in
// OpenBurnBarCore after WS-C2. This file keeps mac-only bridge status and re-exports.

typealias ProviderQuotaSourceKind = OpenBurnBarCore.ProviderQuotaSourceKind
typealias ProviderQuotaConfidence = OpenBurnBarCore.ProviderQuotaConfidence
typealias ProviderQuotaUnit = OpenBurnBarCore.ProviderQuotaUnit
typealias ProviderQuotaWindowKind = OpenBurnBarCore.ProviderQuotaWindowKind
typealias ProviderQuotaBucket = OpenBurnBarCore.ProviderQuotaBucket
typealias ProviderQuotaSnapshot = OpenBurnBarCore.ProviderQuotaSnapshot

typealias MiniMaxQuotaMode = OpenBurnBarCore.MiniMaxQuotaMode
typealias FactoryQuotaPlanTier = OpenBurnBarCore.FactoryQuotaPlanTier
typealias XAIQuotaPlanTier = OpenBurnBarCore.XAIQuotaPlanTier
typealias CodexQuotaScanPolicy = OpenBurnBarCore.CodexQuotaScanPolicy
typealias MiniMaxAPIKeyKind = OpenBurnBarCore.MiniMaxAPIKeyKind

// MARK: - Claude statusline bridge (macOS glue; not lifted to Core)

struct ClaudeQuotaBridgeStatus: Equatable {
    enum State: Equatable {
        case notInstalled
        case awaitingFirstPayload
        case ready
        case disabledByHooks
        case invalidConfiguration
    }

    let state: State
    let wrapperPath: String
    let detailText: String
    let lastPayloadAt: Date?

    var isInstalled: Bool {
        switch state {
        case .awaitingFirstPayload, .ready, .disabledByHooks:
            return true
        case .notInstalled, .invalidConfiguration:
            return false
        }
    }
}