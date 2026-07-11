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

// MARK: - Claude statusline bridge (macOS glue; types in OpenBurnBarCore)

typealias ClaudeQuotaBridgeStatus = OpenBurnBarCore.ClaudeQuotaBridgeStatus
