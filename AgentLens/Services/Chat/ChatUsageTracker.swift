import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

// MARK: - Chat usage tracker

/// Non-`@MainActor` owner of in-app chat usage attribution.
///
/// `ChatSessionController.saveUsageIfNeeded` previously ran provider/model
/// resolution, cost pricing, and ledger persistence inline on the main actor at
/// the end of every stream. The tracker moves the pure mapping + pricing work
/// off the main actor; only the ledger write hops back via the injected
/// `@MainActor` dependencies. Persistence inputs that live on the controller
/// (per-backend model selections, advertised model names) are captured into
/// `ModelNames` on the main actor and passed in as a value, so the mapping
/// semantics stay byte-for-byte identical to the inlined version.
actor ChatUsageTracker {
    /// Ledger-write dependencies. `@MainActor`-isolated because `DataStore` is
    /// a `@MainActor` facade; the tracker awaits them after computing the
    /// `TokenUsage` row off the main thread.
    struct Dependencies: Sendable {
        var insertUsage: @MainActor @Sendable (TokenUsage) async throws -> Void
        var reloadUsages: @MainActor @Sendable () async -> Void
    }

    /// Main-actor-owned model-name inputs, snapshotted per save.
    struct ModelNames: Sendable {
        var hermesModelName: String?
        var piAgentModelName: String?
        var codex: String = ""
        var claude: String = ""
        var droid: String = ""
        var forge: String = ""
        var antigravity: String = ""
        var cursorAgent: String = ""
        var openClaude: String = ""
        var omp: String = ""
        var junie: String = ""
        var fx: String = ""

        init(
            hermesModelName: String? = nil,
            piAgentModelName: String? = nil,
            codex: String = "",
            claude: String = "",
            droid: String = "",
            forge: String = "",
            antigravity: String = "",
            cursorAgent: String = "",
            openClaude: String = "",
            omp: String = "",
            junie: String = "",
            fx: String = ""
        ) {
            self.hermesModelName = hermesModelName
            self.piAgentModelName = piAgentModelName
            self.codex = codex
            self.claude = claude
            self.droid = droid
            self.forge = forge
            self.antigravity = antigravity
            self.cursorAgent = cursorAgent
            self.openClaude = openClaude
            self.omp = omp
            self.junie = junie
            self.fx = fx
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Prices `usageSnapshot` and persists the resulting ledger row. No-op
    /// when there is no snapshot (streams that never reported usage).
    func saveUsageIfNeeded(
        _ usageSnapshot: CLIUsageSnapshot?,
        backend: ChatBackendID,
        requestModel: String,
        modelNames: ModelNames,
        threadID: String,
        responseMessageID: String,
        startedAt: Date,
        endedAt: Date
    ) async {
        guard let usageSnapshot else { return }

        let (provider, projectLabel, model): (AgentProvider, String, String) = {
            switch backend {
            case .hermes:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? modelNames.hermesModelName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "hermes"
                return (.hermes, "OpenBurnBar Hermes Chat", m)
            case .openclaw:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "unselected"
                return (.openClaw, "OpenBurnBar OpenClaw Chat", m)
            case .piAgent:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? modelNames.piAgentModelName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "pi"
                return (.piAgent, "OpenBurnBar Pi Agent Chat", m)
            case .codex:
                let m = modelNames.codex.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "codex"
                return (.codex, "OpenBurnBar Codex Chat", m)
            case .claude:
                let m = modelNames.claude.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "claude"
                return (.claudeCode, "OpenBurnBar Claude Chat", m)
            case .droid:
                let m = modelNames.droid.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "droid"
                return (.factory, "OpenBurnBar Droid Chat", m)
            case .forge:
                let m = modelNames.forge.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "forge"
                return (.forgeDev, "OpenBurnBar Forge Chat", m)
            case .antigravity:
                let m = modelNames.antigravity.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "antigravity"
                return (.antigravity, "OpenBurnBar Antigravity Chat", m)
            case .cursorAgent:
                let m = modelNames.cursorAgent.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "cursor-agent"
                return (.cursorAgent, "OpenBurnBar Cursor Agent Chat", m)
            case .openClaude:
                let m = modelNames.openClaude.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "openclaude"
                return (.openClaude, "OpenBurnBar OpenClaude Chat", m)
            case .omp:
                let m = modelNames.omp.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "omp"
                return (.omp, "OpenBurnBar OMP Chat", m)
            case .junie:
                let m = modelNames.junie.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "junie"
                return (.junie, "OpenBurnBar Junie Chat", m)
            case .fx:
                let m = modelNames.fx.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "fx"
                return (.fx, "OpenBurnBar fx Chat", m)
            // The provider spelling for Grok is `.xAI`; `AgentProvider` has no `.grok`
            // member, and Kimi has its own `.kimi` rather than being filed under Grok.
            // Honour an explicitly requested model like every other backend above,
            // rather than always reporting the default (from #2384).
            case .grok:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "grok"
                return (.xAI, "OpenBurnBar Grok Chat", m)
            case .kimi:
                let m = requestModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "kimi"
                return (.kimi, "OpenBurnBar Kimi Chat", m)
            }
        }()

        let pricing = OpenBurnBarLogParsers.ModelPricing.lookup(model: model)
        let cost: Double
        do {
            cost = try pricing.cost(
                inputTokens: usageSnapshot.inputTokens,
                outputTokens: usageSnapshot.outputTokens,
                cacheCreationTokens: usageSnapshot.cacheCreationTokens,
                cacheReadTokens: usageSnapshot.cacheReadTokens,
                reasoningTokens: usageSnapshot.reasoningTokens
            )
        } catch {
            AppLogger.chat.silentFailure("price in-app chat usage", error: error)
            return
        }
        let usage = TokenUsage(
            provider: provider,
            sessionId: "\(threadID)/\(responseMessageID)",
            projectName: projectLabel,
            model: model,
            inputTokens: usageSnapshot.inputTokens,
            outputTokens: usageSnapshot.outputTokens,
            cacheCreationTokens: usageSnapshot.cacheCreationTokens,
            cacheReadTokens: usageSnapshot.cacheReadTokens,
            reasoningTokens: usageSnapshot.reasoningTokens,
            costUSD: cost,
            startTime: startedAt,
            endTime: endedAt,
            usageSource: .inAppChat,
            provenanceMethod: .inAppChat,
            provenanceConfidence: .exact
        )

        do {
            try await dependencies.insertUsage(usage)
            await dependencies.reloadUsages()
        } catch {
            AppLogger.chat.silentFailure("insert in-app chat usage", error: error)
        }
    }
}
