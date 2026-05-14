import Foundation
import SwiftUI
import OpenBurnBarCore

/// Top-level environment object that owns the Insights tab's mutable state
/// on macOS: the canvas store, the model catalog, the cache, the audit
/// log, and the current canvas selection.
///
/// All view models on the macOS shell read from this single object.
@Observable
@MainActor
final class InsightsMacEnvironment {

    var canvases: [InsightCanvas] = []
    var selectedCanvasID: UUID?
    var selectedWidgetID: UUID?
    var isComposing: Bool = false
    var composerPrompt: String = ""
    var composerError: String?
    var thinkingLog: [String] = []
    var modelCatalog: [InsightCatalogModel] = []
    var selectedModelTag: InsightModelTag {
        didSet { persistModelPreference() }
    }
    var privacyMode: Bool = false {
        didSet { persistModelPreference() }
    }
    var lastInvestigationUsage: InsightTokenUsage?
    var currentAnalysis: InsightAnalysisResult?

    let dataStore: DataStore
    let dataSource: MacInsightDataSource
    let store: InsightCanvasStore
    let auditLog: InsightAuditLog
    let cache: InsightCache
    let catalog: InsightModelCatalog
    let investigation: InsightInvestigation
    let toolBroker: InsightToolBroker
    let executor: InsightExecutor
    let digestBuilder: InsightDigestBuilder
    let aggregator: InsightAggregator
    let analysisEngine: MacInsightAnalysisEngine

    init(dataStore: DataStore) throws {
        let supportDir = try Self.applicationSupportDirectory()
        let insightsDir = supportDir.appendingPathComponent("Insights", isDirectory: true)
        let cacheDir = insightsDir.appendingPathComponent("cache", isDirectory: true)

        self.dataStore = dataStore
        let source = MacInsightDataSource(dataStore: dataStore)
        self.dataSource = source

        self.store = try InsightCanvasStore(fileURL: insightsDir.appendingPathComponent("canvases.json"))
        self.auditLog = try InsightAuditLog(fileURL: insightsDir.appendingPathComponent("audit.jsonl"))
        self.cache = try InsightCache(directoryURL: cacheDir)
        let catalog = InsightModelCatalog()
        self.catalog = catalog
        self.executor = InsightExecutor()
        self.digestBuilder = InsightDigestBuilder()
        self.aggregator = InsightAggregator(digestBuilder: digestBuilder)
        let broker = InsightToolBroker(dataSource: source)
        self.toolBroker = broker
        self.analysisEngine = MacInsightAnalysisEngine(
            auditLog: InsightAnalysisAuditLog(fileURL: insightsDir.appendingPathComponent("analysis-audit.jsonl")),
            cache: InsightAnalysisCache(directoryURL: cacheDir.appendingPathComponent("analysis", isDirectory: true)),
            catalog: catalog,
            toolBroker: broker
        )
        self.investigation = InsightInvestigation(
            catalog: catalog,
            cache: cache,
            auditLog: auditLog,
            toolBroker: toolBroker
        )

        let fallbackModel = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        let saved = Self.loadModelPreference(defaults: .standard)
        self.selectedModelTag = saved.explicitModel ?? fallbackModel
        self.privacyMode = saved.restrictToLocalOnly

        Task {
            await registerAvailableAnalysisGateways()
            await refreshCatalog()
            await loadInitialCanvases()
        }
    }

    // MARK: - Catalog

    func refreshCatalog() async {
        modelCatalog = await catalog.allModels(refresh: true)
        applyAutomaticModelSelectionIfNeeded()
    }

    // MARK: - Loading

    func loadInitialCanvases() async {
        let existing = await store.allCanvases()
        if existing.isEmpty {
            await seedInitialCanvas()
        }
        canvases = await store.allCanvases()
        if selectedCanvasID == nil { selectedCanvasID = canvases.first?.id }
        await refreshSelectedCanvasData()
    }

    private func seedInitialCanvas() async {
        let filter = InsightFilter(window: .last7d)
        do {
            let snapshot = try await dataSource.snapshot(window: filter.window.interval())
            let result = try await runAnalysis(
                prompt: "Generate the default Insights intelligence brief.",
                snapshot: snapshot,
                filter: filter,
                canvas: nil,
                instruction: .defaultBrief
            )
            currentAnalysis = result
            let canvas = RuleBasedInsightAnalysisEngine.materializeCanvas(
                from: result,
                prompt: "Default intelligence brief"
            )
            try? await store.upsert(canvas)
            selectedCanvasID = canvas.id
        } catch {
            let template = InsightsBuiltInTemplates.today
            var canvas = template.instantiate()
            canvas.modelTag = selectedModelTag
            try? await store.upsert(canvas)
        }
    }

    // MARK: - Refresh

    /// Recompute every widget's data from the current snapshot.
    func refreshSelectedCanvasData() async {
        guard var canvas = currentCanvas else { return }
        let snapshot: InsightDataSnapshot
        do {
            snapshot = try await dataSource.snapshot(window: canvas.filter.window.interval())
        } catch {
            composerError = error.localizedDescription
            return
        }
        for idx in canvas.widgets.indices {
            var widget = canvas.widgets[idx]
            widget.data = executor.evaluate(
                binding: widget.dataBinding,
                filter: canvas.filter.overlaid(by: widget.filter),
                snapshot: snapshot
            )
            widget.freshness = .fresh
            widget.lastComputedAt = Date()
            canvas.widgets[idx] = widget
        }
        canvas.lastRefreshedAt = Date()
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()

        do {
            currentAnalysis = try await runAnalysis(
                prompt: "Refresh the default Insights intelligence brief.",
                snapshot: snapshot,
                filter: canvas.filter,
                canvas: canvas,
                instruction: .defaultBrief
            )
        } catch {
            composerError = error.localizedDescription
        }
    }

    // MARK: - Composition

    func compose(prompt: String) async {
        guard !prompt.isEmpty else { return }
        composerError = nil
        isComposing = true
        defer { isComposing = false }

        let snapshot: InsightDataSnapshot
        do {
            snapshot = try await dataSource.snapshot(window: currentCanvas?.filter.window.interval()
                                                              ?? InsightTimeWindow.last7d.interval())
        } catch {
            composerError = error.localizedDescription
            return
        }
        do {
            let filter = currentCanvas?.filter ?? InsightFilter(window: .last7d)
            let result = try await runAnalysis(
                prompt: prompt,
                snapshot: snapshot,
                filter: filter,
                canvas: currentCanvas,
                instruction: .answerFollowUp
            )
            currentAnalysis = result
            let canvas = RuleBasedInsightAnalysisEngine.materializeCanvas(from: result, prompt: prompt)
            try? await store.upsert(canvas)
            selectedCanvasID = canvas.id
            canvases = await store.allCanvases()
        } catch {
            composerError = error.localizedDescription
        }
    }

    private func runAnalysis(
        prompt: String,
        snapshot: InsightDataSnapshot,
        filter: InsightFilter,
        canvas: InsightCanvas?,
        instruction: InsightAnalysisRequest.Instruction
    ) async throws -> InsightAnalysisResult {
        let context = try aggregator.buildContext(
            snapshot: snapshot,
            filter: filter,
            includedDataSources: [
                "local_session_logs",
                "datastore_usage",
                "firestore_rollups",
                "quota_snapshots",
                "provider_account_state",
                "chart_studio_refs",
                "prior_insight_runs",
                "audit_history"
            ],
            priorRunSummaries: try await recentAnalysisSummaries()
        )
        let analysisModel = modelForAnalysis(instruction: instruction)
        let request = InsightAnalysisRequest(
            prompt: prompt,
            context: context,
            currentCanvas: canvas,
            selectedModel: analysisModel,
            instruction: instruction,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 8
        )
        await analysisEngine.updateConfiguration(.init(
            privacyModeRestrictsToLocal: privacyMode,
            failWhenSelectedGatewayUnavailable: true
        ))
        let result = try await analysisEngine.analyze(request)
        try? await auditLog.append(.init(
            id: result.auditID ?? UUID(),
            canvasID: canvas?.id,
            prompt: prompt,
            modelTag: result.modelTag,
            egressTier: result.modelTag.egressTier,
            digestBytes: context.budgetReport.encodedBytes,
            digestContentHash: context.digest.contentHash,
            instruction: "analysis.\(instruction.rawValue)",
            tokenUsage: result.tokenUsage,
            completedAt: result.generatedAt,
            status: .succeeded
        ))
        return result
    }

    private func registerAvailableAnalysisGateways() async {
        let providerAliases = [
            "openai",
            "anthropic",
            "claude",
            "minimax",
            "zai",
            "z.ai",
            "kimi",
            "moonshot"
        ]
        var providerKeys: [String: String] = [:]
        let providerKeyStore = ProviderAPIKeyStore.shared
        let mirrorKeychain = KeychainStore()
        for alias in providerAliases {
            if let value = providerKeyStore.apiKey(for: alias)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                providerKeys[alias] = value
                continue
            }
            let mirrorAccount = "provider.\(alias).apiKey"
            let raw = try? mirrorKeychain.string(for: mirrorAccount, allowUserInteraction: false)
            if let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                providerKeys[alias] = value
            }
        }
        let environment = ProcessInfo.processInfo.environment

        await InsightProviderGatewayRegistry.registerDefaultSwiftGateways(
            in: catalog,
            keyProvider: { provider, aliases, envKeys in
                let candidates = [provider] + aliases
                for candidate in candidates {
                    if let key = providerKeys[candidate] {
                        return key
                    }
                }
                for key in envKeys {
                    if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        return value
                    }
                }
                return nil
            },
            urlProvider: { key in
                guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else {
                    return nil
                }
                return URL(string: raw)
            },
            hermesProvider: {
                // macOS owns its Hermes runtime via the daemon — always
                // register the local relay as an Insights gateway so the
                // user's follow-up taps stream through Hermes by default,
                // no API keys required. `HERMES_BASE_URL` lets advanced
                // users redirect to a different relay (e.g. a remote
                // session shared from another machine).
                let envURL = environment["HERMES_BASE_URL"]
                    .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let baseURL = envURL ?? URL(string: "http://127.0.0.1:8642")!
                let transport = HermesInsightHTTPTransport(
                    baseURL: baseURL,
                    advertisedModels: HermesInsightAdapter.defaultModels
                )
                return HermesInsightAdapter(
                    transport: transport,
                    availableModels: HermesInsightAdapter.defaultModels
                )
            }
        )
    }

    private func applyAutomaticModelSelectionIfNeeded() {
        let preference = Self.loadModelPreference(defaults: .standard)
        guard preference.mode == .automatic else { return }
        let available = privacyMode
            ? modelCatalog.filter { $0.egressTier == .localOnly }
            : modelCatalog
        let preferred = available.first { $0.providerKey == "hermes" }
            ?? available.first { $0.providerKey == "ollama" }
            ?? available.first { $0.providerKey == "local-rules" }
        guard let preferred else { return }
        selectedModelTag = .init(
            providerKey: preferred.providerKey,
            modelID: preferred.id,
            displayName: preferred.displayName,
            egressTier: preferred.egressTier
        )
    }

    private func modelForAnalysis(instruction: InsightAnalysisRequest.Instruction) -> InsightModelTag {
        guard instruction == .answerFollowUp else { return selectedModelTag }
        guard selectedModelTag.providerKey == "local-rules" else { return selectedModelTag }
        let available = privacyMode
            ? modelCatalog.filter { $0.egressTier == .localOnly }
            : modelCatalog
        let preferred = available.first { $0.providerKey == "hermes" }
            ?? available.first { $0.egressTier != .localOnly && $0.providerKey != "ollama" }
            ?? available.first { $0.providerKey == "ollama" }
            ?? available.first { $0.providerKey != "local-rules" }
        guard let preferred else { return selectedModelTag }
        return .init(
            providerKey: preferred.providerKey,
            modelID: preferred.id,
            displayName: preferred.displayName,
            egressTier: preferred.egressTier
        )
    }

    private func persistModelPreference() {
        let preference = InsightModelPreference(
            mode: selectedModelTag.providerKey == "local-rules" ? .automatic : .explicit,
            explicitModel: selectedModelTag,
            restrictToLocalOnly: privacyMode,
            maxEgressTier: privacyMode ? .localOnly : nil,
            deepTranscriptOptIn: false
        )
        guard let data = try? JSONEncoder().encode(preference) else { return }
        UserDefaults.standard.set(data, forKey: Self.modelPreferenceDefaultsKey)
    }

    private static let modelPreferenceDefaultsKey = "insights.modelPreference.v1"

    private static func loadModelPreference(defaults: UserDefaults) -> InsightModelPreference {
        guard let data = defaults.data(forKey: modelPreferenceDefaultsKey),
              let preference = try? JSONDecoder().decode(InsightModelPreference.self, from: data)
        else {
            return .default
        }
        return preference
    }

    private func recentAnalysisSummaries() async throws -> [String] {
        try await auditLog.readAll(limit: 10)
            .filter { $0.instruction.hasPrefix("analysis.") }
            .map { "\($0.startedAt.formatted(date: .abbreviated, time: .shortened)): \($0.instruction) via \($0.modelTag.displayName)" }
    }

    // MARK: - Mutations

    var currentCanvas: InsightCanvas? {
        guard let id = selectedCanvasID else { return canvases.first }
        return canvases.first { $0.id == id } ?? canvases.first
    }

    func createCanvas(from template: InsightCanvasTemplate) async {
        let canvas = template.instantiate()
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
        selectedCanvasID = canvas.id
        await refreshSelectedCanvasData()
    }

    func deleteCurrentCanvas() async {
        guard let id = selectedCanvasID else { return }
        try? await store.remove(id: id)
        canvases = await store.allCanvases()
        selectedCanvasID = canvases.first?.id
    }

    func updateCanvas(_ canvas: InsightCanvas) async {
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
    }

    func addWidget(_ widget: InsightWidget) async {
        guard var canvas = currentCanvas else { return }
        canvas.add(widget)
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
        await refreshSelectedCanvasData()
    }

    func pinGeneratedWidget(_ generated: InsightGeneratedWidget) async {
        guard var canvas = currentCanvas else { return }
        if let existing = canvas.widgets.firstIndex(where: { $0.id == generated.widget.id }) {
            canvas.widgets[existing] = generated.widget
        } else {
            canvas.widgets.append(generated.widget)
        }
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
    }

    func removeWidget(id widgetID: UUID) async {
        guard var canvas = currentCanvas else { return }
        canvas.remove(widgetID: widgetID)
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
    }

    func moveWidget(id widgetID: UUID, column: Int, row: Int) async {
        guard var canvas = currentCanvas else { return }
        canvas.layout.move(widgetID: widgetID, toColumn: column, toRow: row)
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
    }

    func resizeWidget(id widgetID: UUID, colSpan: Int, rowSpan: Int) async {
        guard var canvas = currentCanvas else { return }
        canvas.layout.resize(widgetID: widgetID, colSpan: colSpan, rowSpan: rowSpan)
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
    }

    // MARK: - Paths

    private static func applicationSupportDirectory() throws -> URL {
        let manager = FileManager.default
        let url = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OpenBurnBar", isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
