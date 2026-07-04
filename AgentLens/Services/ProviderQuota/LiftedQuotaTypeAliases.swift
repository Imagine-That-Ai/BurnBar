import Foundation
import OpenBurnBarCore

// MARK: - Lifted quota aliases (Mac side ↔ OpenBurnBarCore canonical)
//
// WS-C2 quota lift: CLEAN adapters, protocol/context, models, and support
// infra compile in `OpenBurnBarCore` for Windows parity. Re-export here so
// AgentLens call sites keep working without sprinkling imports.

typealias ProviderQuotaAdapter = OpenBurnBarCore.ProviderQuotaAdapter
typealias ProviderQuotaAdapterContext = OpenBurnBarCore.ProviderQuotaAdapterContext
typealias QuotaServiceError = OpenBurnBarCore.QuotaServiceError
typealias FlexibleQuotaBucketNormalizer = OpenBurnBarCore.FlexibleQuotaBucketNormalizer

typealias AiderQuotaAdapter = OpenBurnBarCore.AiderQuotaAdapter
typealias AntigravityQuotaAdapter = OpenBurnBarCore.AntigravityQuotaAdapter
typealias CopilotQuotaAdapter = OpenBurnBarCore.CopilotQuotaAdapter
typealias FactoryQuotaAdapter = OpenBurnBarCore.FactoryQuotaAdapter
typealias HermesQuotaAdapter = OpenBurnBarCore.HermesQuotaAdapter
typealias KiloCodeQuotaAdapter = OpenBurnBarCore.KiloCodeQuotaAdapter
typealias KimiQuotaAdapter = OpenBurnBarCore.KimiQuotaAdapter
typealias OllamaQuotaAdapter = OpenBurnBarCore.OllamaQuotaAdapter

typealias ClineQuotaAdapter = OpenBurnBarCore.ClineQuotaAdapter
typealias RooCodeQuotaAdapter = OpenBurnBarCore.RooCodeQuotaAdapter
typealias AugmentQuotaAdapter = OpenBurnBarCore.AugmentQuotaAdapter
typealias GooseQuotaAdapter = OpenBurnBarCore.GooseQuotaAdapter
typealias OpenClawQuotaAdapter = OpenBurnBarCore.OpenClawQuotaAdapter
typealias OpenClaudeQuotaAdapter = OpenBurnBarCore.OpenClaudeQuotaAdapter
typealias WindsurfQuotaAdapter = OpenBurnBarCore.WindsurfQuotaAdapter
typealias GeminiCLIQuotaAdapter = OpenBurnBarCore.GeminiCLIQuotaAdapter

typealias ClaudeCredentialsReading = OpenBurnBarCore.ClaudeCredentialsReading
typealias ClaudeOAuthCredentials = OpenBurnBarCore.ClaudeOAuthCredentials
typealias NoClaudeCredentialsReader = OpenBurnBarCore.NoClaudeCredentialsReader
typealias StaticClaudeCredentialsReader = OpenBurnBarCore.StaticClaudeCredentialsReader
typealias ClaudeCredentialsReader = OpenBurnBarCore.ClaudeCredentialsReader

typealias FactoryDashboardScraper = OpenBurnBarCore.FactoryDashboardScraper
typealias OllamaCloudScraper = OpenBurnBarCore.OllamaCloudScraper
typealias WarpAPIFetcher = OpenBurnBarCore.WarpAPIFetcher
typealias CodexRolloutScanner = OpenBurnBarCore.CodexRolloutScanner
typealias XAISuperGrokUsageLog = OpenBurnBarCore.XAISuperGrokUsageLog
typealias FactoryCookieExtractor = OpenBurnBarCore.FactoryCookieExtractor
typealias FactorySessionClassifier = OpenBurnBarCore.FactorySessionClassifier

typealias SecretStore = OpenBurnBarCore.SecretStore
typealias CLIExecutor = OpenBurnBarCore.CLIExecutor
typealias QuotaLogger = OpenBurnBarCore.QuotaLogger
typealias ProviderQuotaSnapshotPersisting = OpenBurnBarCore.ProviderQuotaSnapshotPersisting
typealias ClaudeQuotaBridgeManaging = OpenBurnBarCore.ClaudeQuotaBridgeManaging



typealias CursorUsageSummary = OpenBurnBarCore.CursorUsageSummary
typealias CursorUserInfo = OpenBurnBarCore.CursorUserInfo


func quotaNonEmpty(_ value: String?) -> String? {
    OpenBurnBarCore.quotaNonEmpty(value)
}
