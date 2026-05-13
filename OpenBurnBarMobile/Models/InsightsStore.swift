import Foundation
import SwiftUI
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
    var selectedModelTag: InsightModelTag
    var privacyMode: Bool = false

    let dataSource: InsightDataSource
    let store: InsightCanvasStore
    let auditLog: InsightAuditLog
    let cache: InsightCache
    let catalog: InsightModelCatalog
    let investigation: InsightInvestigation
    let toolBroker: InsightToolBroker
    let executor: InsightExecutor
    let digestBuilder: InsightDigestBuilder

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
        self.toolBroker = InsightToolBroker(dataSource: dataSource)
        self.investigation = InsightInvestigation(
            catalog: catalog,
            cache: cache,
            auditLog: auditLog,
            toolBroker: toolBroker
        )
        self.selectedModelTag = .init(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        Task {
            await catalog.register(LocalRuleBasedAdapter())
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
    }

    func loadInitial() async {
        let existing = await store.allCanvases()
        if existing.isEmpty {
            let template = MobileInsightsTemplates.today
            let canvas = template.instantiate()
            try? await store.upsert(canvas)
        }
        canvases = await store.allCanvases()
        if selectedCanvasID == nil { selectedCanvasID = canvases.first?.id }
        await refreshSelectedCanvas()
    }

    func refreshSelectedCanvas() async {
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
    }

    func compose(prompt: String) async {
        guard !prompt.isEmpty else { return }
        composerError = nil
        isComposing = true
        defer { isComposing = false }
        let snapshot: InsightDataSnapshot
        do {
            snapshot = try await dataSource.snapshot(
                window: (currentCanvas?.filter.window ?? .last7d).interval()
            )
        } catch {
            composerError = error.localizedDescription
            return
        }
        let digest: InsightDigest
        do {
            digest = try digestBuilder.build(
                from: snapshot,
                filter: currentCanvas?.filter ?? InsightFilter(window: .last7d)
            )
        } catch {
            composerError = error.localizedDescription
            return
        }
        let request = InsightInvestigateRequest(
            prompt: prompt,
            digest: digest,
            canvas: currentCanvas,
            modelTag: selectedModelTag,
            capabilityTier: .strictJSONSchema,
            instruction: currentCanvas == nil ? .composeCanvas : .refineCanvas
        )
        await investigation.updateConfiguration(.init(privacyModeRestrictsToLocal: privacyMode))
        do {
            for try await event in await investigation.run(request) {
                switch event {
                case .partialCanvas(let partial):
                    var updated = partial
                    updated.modelTag = selectedModelTag
                    try? await store.upsert(updated)
                    selectedCanvasID = updated.id
                    canvases = await self.store.allCanvases()
                case .widgetReady(let widget):
                    if var canvas = currentCanvas {
                        if canvas.widgets.contains(where: { $0.id == widget.id }) {
                            canvas.replace(widget)
                        } else {
                            canvas.add(widget)
                        }
                        try? await self.store.upsert(canvas)
                        canvases = await self.store.allCanvases()
                    }
                case .finalCanvas(let final):
                    var updated = final
                    updated.modelTag = selectedModelTag
                    try? await self.store.upsert(updated)
                    selectedCanvasID = updated.id
                default:
                    break
                }
            }
            canvases = await self.store.allCanvases()
            await refreshSelectedCanvas()
        } catch {
            composerError = error.localizedDescription
        }
    }

    func createCanvas(from template: InsightCanvasTemplate) async {
        let canvas = template.instantiate()
        try? await store.upsert(canvas)
        canvases = await store.allCanvases()
        selectedCanvasID = canvas.id
        await refreshSelectedCanvas()
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
