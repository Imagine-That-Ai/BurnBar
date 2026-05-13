import Foundation
import Security
import SwiftUI
import UIKit
import OpenBurnBarCore

/// Observable wrapper around the Insights services for the mobile shell.
///
/// Owns the catalog, store, cache, audit log, and the current canvas
/// selection. The mobile shell reads this single object via
/// `@Bindable` and renders the canvas grid + composer.
@Observable
@MainActor
final class InsightsStore {

    var canvases: [InsightCanvas] = []
    var selectedCanvasID: UUID?
    var selectedWidgetID: UUID?
    var isComposing: Bool = false
    var composerPrompt: String = ""
    var composerError: String?
    var modelCatalog: [InsightCatalogModel] = []
    var selectedModelTag: InsightModelTag {
        didSet { persistModelPreference() }
    }
    var privacyMode: Bool = false {
        didSet { persistModelPreference() }
    }
    var currentAnalysis: InsightAnalysisResult?

    let dataSource: InsightDataSource
    let store: InsightCanvasStore
    let auditLog: InsightAuditLog
    let cache: InsightCache
    let catalog: InsightModelCatalog
    let investigation: InsightInvestigation
    let toolBroker: InsightToolBroker
    let executor: InsightExecutor
    let digestBuilder: InsightDigestBuilder
    let aggregator: InsightAggregator
    let analysisEngine: MobileInsightAnalysisEngine

    init(dataSource: InsightDataSource) throws {
        self.dataSource = dataSource
        let supportDir = try Self.applicationSupportDirectory()
        let dir = supportDir.appendingPathComponent("Insights", isDirectory: true)
        self.store = try InsightCanvasStore(fileURL: dir.appendingPathComponent("canvases.json"))
        self.auditLog = try InsightAuditLog(fileURL: dir.appendingPathComponent("audit.jsonl"))
        self.cache = try InsightCache(directoryURL: dir.appendingPathComponent("cache"))
        let catalog = InsightModelCatalog()
        self.catalog = catalog
        self.executor = InsightExecutor()
        self.digestBuilder = InsightDigestBuilder()
        self.aggregator = InsightAggregator(digestBuilder: digestBuilder)
        let broker = InsightToolBroker(dataSource: dataSource)
        self.toolBroker = broker
        self.analysisEngine = MobileInsightAnalysisEngine(
            platform: Self.currentAnalysisPlatform,
            auditLog: InsightAnalysisAuditLog(fileURL: dir.appendingPathComponent("analysis-audit.jsonl")),
            cache: InsightAnalysisCache(directoryURL: dir.appendingPathComponent("analysis-cache", isDirectory: true)),
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
            await loadInitial()
        }
    }

    var currentCanvas: InsightCanvas? {
        guard let id = selectedCanvasID else { return canvases.first }
        return canvases.first { $0.id == id } ?? canvases.first
    }

    func refreshCatalog() async {
        modelCatalog = await catalog.allModels(refresh: true)
        applyAutomaticModelSelectionIfNeeded()
    }

    func loadInitial() async {
        let existing = await store.allCanvases()
        if existing.isEmpty {
            await seedInitialAnalysisCanvas()
        }
        canvases = await store.allCanvases()
        if selectedCanvasID == nil { selectedCanvasID = canvases.first?.id }
        await refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: true)
    }

    private func seedInitialAnalysisCanvas() async {
        let filter = InsightFilter(window: .last7d)
        do {
            let snapshot = try await makeSnapshot(for: filter.window)
            let result = try await runAnalysis(
                prompt: "Generate the default mobile Insights intelligence brief.",
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
            let template = MobileInsightsTemplates.today
            var canvas = template.instantiate()
            canvas.modelTag = selectedModelTag
            try? await store.upsert(canvas)
        }
    }

    func refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: Bool = true) async {
        guard var canvas = currentCanvas else { return }
        if autoSwitchEmptyDefaultCanvas,
           let replacement = await dataBackedReplacement(for: canvas) {
            canvas = replacement
        }
        let snapshot: InsightDataSnapshot
        do {
            snapshot = try await makeSnapshot(for: canvas.filter.window)
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
                prompt: "Refresh the mobile Insights intelligence brief.",
                snapshot: snapshot,
                filter: canvas.filter,
                canvas: canvas,
                instruction: .defaultBrief
            )
        } catch {
            composerError = error.localizedDescription
        }
    }

    func compose(prompt: String) async {
        guard !prompt.isEmpty else { return }
        composerError = nil
        isComposing = true
        defer { isComposing = false }
        let snapshot: InsightDataSnapshot
        do {
            snapshot = try await makeSnapshot(for: currentCanvas?.filter.window ?? .last7d)
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
            canvases = await self.store.allCanvases()
            await refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: false)
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
                "firestore_rollups",
                "mobile_rollups",
                "quota_snapshots",
                "provider_summaries",
                "model_summaries",
                "chart_studio_refs",
                "prior_insight_runs",
                "audit_history"
            ],
            priorRunSummaries: try await recentAnalysisSummaries()
        )
        let request = InsightAnalysisRequest(
            prompt: prompt,
            context: context,
            currentCanvas: canvas,
            selectedModel: selectedModelTag,
            instruction: instruction,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 6
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
            modelTag: selectedModelTag,
            egressTier: selectedModelTag.egressTier,
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
        await InsightProviderGatewayRegistry.registerDefaultSwiftGateways(
            in: catalog,
            keyProvider: { provider, aliases, envKeys in
                Self.mobileUserKey(provider: provider, aliases: aliases, envKeys: envKeys)
            },
            urlProvider: { Self.urlFromEnvironment($0) }
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

    private static var currentAnalysisPlatform: InsightAnalysisPlatform {
        UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
    }

    private static func loadModelPreference(defaults: UserDefaults) -> InsightModelPreference {
        guard let data = defaults.data(forKey: modelPreferenceDefaultsKey),
              let preference = try? JSONDecoder().decode(InsightModelPreference.self, from: data)
        else {
            return .default
        }
        return preference
    }

    nonisolated private static func mobileUserKey(provider: String, aliases: [String] = [], envKeys: [String]) -> String? {
        let candidates = [provider] + aliases
        for candidate in candidates {
            if let key = storedMobileCredential(provider: candidate)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
        }
        let env = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated private static func storedMobileCredential(provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "escrow_\(provider)",
            kSecAttrService as String: "com.openburnbar.mobile",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credential = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return credential
    }

    nonisolated private static func urlFromEnvironment(_ key: String) -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private func recentAnalysisSummaries() async throws -> [String] {
        try await auditLog.readAll(limit: 10)
            .filter { $0.instruction.hasPrefix("analysis.") }
            .map { "\($0.startedAt.formatted(date: .abbreviated, time: .shortened)): \($0.instruction) via \($0.modelTag.displayName)" }
    }

    func createCanvas(from template: InsightCanvasTemplate) async {
        let canvas = template.instantiate()
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
        selectedCanvasID = canvas.id
        await refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: false)
    }

    func updateCanvas(_ canvas: InsightCanvas) async {
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
    }

    func deleteCurrentCanvas() async {
        guard let id = selectedCanvasID else { return }
        try? await store.remove(id: id)
        canvases = await store.allCanvases()
        selectedCanvasID = canvases.first?.id
    }

    private func makeSnapshot(for window: InsightTimeWindow) async throws -> InsightDataSnapshot {
        if let mobileDataSource = dataSource as? MobileInsightDataSource {
            return try await mobileDataSource.snapshot(for: window)
        }
        return try await dataSource.snapshot(window: window.interval())
    }

    private func dataBackedReplacement(for canvas: InsightCanvas) async -> InsightCanvas? {
        guard shouldAutoSwitchEmptyDefaultCanvas(canvas) else { return nil }
        guard let currentSnapshot = try? await makeSnapshot(for: canvas.filter.window),
              !currentSnapshot.hasUsableInsightRows
        else {
            return nil
        }
        guard let bestWindow = await firstWindowWithRows(excluding: canvas.filter.window) else {
            return nil
        }
        if let existing = canvases.first(where: { $0.id != canvas.id && $0.filter.window == bestWindow }) {
            selectedCanvasID = existing.id
            return existing
        }

        var replacement = (MobileInsightsTemplates.template(for: bestWindow) ?? MobileInsightsTemplates.weekReview).instantiate()
        replacement.modelTag = selectedModelTag
        try? await store.upsert(replacement)
        canvases = await store.allCanvases()
        selectedCanvasID = replacement.id
        return replacement
    }

    private func shouldAutoSwitchEmptyDefaultCanvas(_ canvas: InsightCanvas) -> Bool {
        switch canvas.origin {
        case .template(let id):
            return id.hasPrefix("mobile-")
        case .composed(let prompt):
            return prompt == "Default intelligence brief"
        case .userCreated, .imported:
            return isLegacyDefaultMobileCanvas(canvas)
        }
    }

    private func isLegacyDefaultMobileCanvas(_ canvas: InsightCanvas) -> Bool {
        guard canvas.title == MobileInsightsTemplates.today.title,
              canvas.filter.window == .today
        else {
            return false
        }
        let defaultTitles = Set(MobileInsightsTemplates.today.instantiate().widgets.map(\.title))
        let canvasTitles = Set(canvas.widgets.map(\.title))
        return defaultTitles.isSubset(of: canvasTitles)
    }

    private func firstWindowWithRows(excluding current: InsightTimeWindow) async -> InsightTimeWindow? {
        for window in Self.dataRecoveryWindowOrder where window != current {
            guard let snapshot = try? await makeSnapshot(for: window),
                  snapshot.hasUsableInsightRows
            else {
                continue
            }
            return window
        }
        return nil
    }

    private static let dataRecoveryWindowOrder: [InsightTimeWindow] = [
        .last7d,
        .last30d,
        .last90d,
        .allTime,
        .today,
        .last24h
    ]

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

/// Compact mobile templates — same shape as the macOS ones but trimmed
/// so they project nicely onto smaller canvases.
enum MobileInsightsTemplates {

    static var all: [InsightCanvasTemplate] {
        [today, weekReview, modelFocus, useCases, quotaHealth]
    }

    static func template(for window: InsightTimeWindow) -> InsightCanvasTemplate? {
        switch window {
        case .today, .last24h:
            return today
        case .last7d:
            return weekReview
        case .last30d:
            return modelFocus
        case .last90d, .last365d, .allTime, .custom:
            return useCases
        }
    }

    static var today: InsightCanvasTemplate {
        .init(
            id: "mobile-today",
            title: "Today",
            summary: "Daily snapshot.",
            symbolName: "sun.max.fill",
            theme: .aurora,
            widgets: [
                widget(.kpiTile, "Cost", .kpi(metric: .totalCost, window: .today)),
                widget(.kpiTile, "Sessions", .kpi(metric: .totalSessions, window: .today)),
                widget(.timeSeriesLine, "Trend",
                       .timeSeries(metric: .cost, dimension: .provider, window: .today)),
                widget(.narrative, "Narrative",
                       .narrative(.init(headline: "Today",
                                          body: "Tap the composer to investigate.")),
                       spec: .narrative(.init()))
            ],
            layout: InsightLayout(columnCount: 6, rowHeight: 110, gap: 12),
            filter: InsightFilter(window: .today)
        )
    }

    static var weekReview: InsightCanvasTemplate {
        .init(
            id: "mobile-week",
            title: "Last 7 days",
            summary: "Cost trend and top models.",
            symbolName: "calendar",
            theme: .ember,
            widgets: [
                widget(.kpiTile, "7d cost", .kpi(metric: .totalCost, window: .last7d)),
                widget(.kpiTile, "Cache hit", .kpi(metric: .cacheHitRate, window: .last7d)),
                widget(.timeSeriesLine, "Cost trend",
                       .timeSeries(metric: .cost, dimension: .provider, window: .last7d)),
                widget(.barRanking, "Top models",
                       .ranking(metric: .cost, dimension: .model, limit: 8, window: .last7d))
            ],
            layout: InsightLayout(columnCount: 6, rowHeight: 110, gap: 12),
            filter: InsightFilter(window: .last7d)
        )
    }

    static var modelFocus: InsightCanvasTemplate {
        .init(
            id: "mobile-model-focus",
            title: "Model Focus",
            summary: "How each model is used.",
            symbolName: "cpu.fill",
            theme: .mercury,
            widgets: [
                widget(.donut, "Model mix",
                       .distribution(metric: .cost, dimension: .model, window: .last30d)),
                widget(.modelFocusMatrix, "Focus by model",
                       .modelFocusMatrix(window: .last30d))
            ],
            layout: InsightLayout(columnCount: 6, rowHeight: 110, gap: 12),
            filter: InsightFilter(window: .last30d)
        )
    }

    static var useCases: InsightCanvasTemplate {
        .init(
            id: "mobile-use-cases",
            title: "Use cases",
            summary: "Topic clusters across recent sessions.",
            symbolName: "tag.circle.fill",
            theme: .whimsy,
            widgets: [
                widget(.useCaseCluster, "Clusters",
                       .useCaseClusters(window: .last30d)),
                widget(.drilldownList, "Recent sessions",
                       .drilldown(limit: 12))
            ],
            layout: InsightLayout(columnCount: 6, rowHeight: 110, gap: 12),
            filter: InsightFilter(window: .last30d)
        )
    }

    static var quotaHealth: InsightCanvasTemplate {
        .init(
            id: "mobile-quota",
            title: "Quota",
            summary: "Provider headroom.",
            symbolName: "gauge.with.dots.needle.67percent",
            theme: .ember,
            widgets: [
                widget(.quotaPulse, "Quota pulse", .quota(providerKey: nil))
            ],
            layout: InsightLayout(columnCount: 6, rowHeight: 110, gap: 12),
            filter: InsightFilter(window: .today)
        )
    }

    private static func widget(_ kind: InsightWidgetKind,
                                _ title: String,
                                _ binding: InsightDataBinding,
                                spec: InsightWidgetSpec? = nil) -> InsightWidget {
        let resolvedSpec: InsightWidgetSpec
        if let spec { resolvedSpec = spec }
        else {
            switch kind {
            case .kpiTile: resolvedSpec = .kpiTile(.init(metricLabel: title))
            case .timeSeriesLine: resolvedSpec = .timeSeries(.init(style: .line))
            case .barRanking: resolvedSpec = .ranking(.init())
            case .donut: resolvedSpec = .distribution(.init(style: .donut))
            case .modelFocusMatrix: resolvedSpec = .modelFocusMatrix(.init())
            case .useCaseCluster: resolvedSpec = .useCaseCluster(.init())
            case .drilldownList: resolvedSpec = .drilldownList(.init())
            case .quotaPulse: resolvedSpec = .quotaPulse(.init())
            case .narrative: resolvedSpec = .narrative(.init())
            default: resolvedSpec = .narrative(.init())
            }
        }
        return InsightWidget(
            kind: kind,
            title: title,
            spec: resolvedSpec,
            dataBinding: binding
        )
    }
}

private extension InsightDataSnapshot {
    var hasUsableInsightRows: Bool {
        !usages.isEmpty
            || !sessions.isEmpty
            || !quotaBuckets.isEmpty
            || !operatingActions.isEmpty
            || !summaryRuns.isEmpty
    }
}
