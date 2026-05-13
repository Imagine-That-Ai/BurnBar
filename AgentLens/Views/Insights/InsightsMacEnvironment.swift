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
    var selectedModelTag: InsightModelTag
    var privacyMode: Bool = false
    var lastInvestigationUsage: InsightTokenUsage?

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
        self.toolBroker = InsightToolBroker(dataSource: source)
        self.investigation = InsightInvestigation(
            catalog: catalog,
            cache: cache,
            auditLog: auditLog,
            toolBroker: toolBroker
        )

        // Local rules adapter is always available.
        self.selectedModelTag = .init(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )

        Task {
            await catalog.register(LocalRuleBasedAdapter())
            await refreshCatalog()
            await loadInitialCanvases()
        }
    }

    // MARK: - Catalog

    func refreshCatalog() async {
        modelCatalog = await catalog.allModels(refresh: true)
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
        // First-run: instantiate the "Today" template so the user sees
        // value immediately, even without any provider configured.
        let template = InsightsBuiltInTemplates.today
        var canvas = template.instantiate()
        canvas.modelTag = .init(
            providerKey: "local-rules", modelID: "local-rules-v1",
            displayName: "Local rules", egressTier: .localOnly
        )
        try? await store.upsert(canvas)
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
        thinkingLog.removeAll()
        do {
            for try await event in await investigation.run(request) {
                switch event {
                case .thinkingDelta(let delta):
                    thinkingLog.append(delta)
                case .partialCanvas(let partial):
                    // Render the in-progress canvas so the user sees
                    // widgets land as the model writes them.
                    var updated = partial
                    updated.modelTag = selectedModelTag
                    try? await store.upsert(updated)
                    selectedCanvasID = updated.id
                    canvases = await store.allCanvases()
                case .widgetReady(let widget):
                    // Patch a single widget into the active canvas.
                    if var canvas = currentCanvas {
                        if canvas.widgets.contains(where: { $0.id == widget.id }) {
                            canvas.replace(widget)
                        } else {
                            canvas.add(widget)
                        }
                        try? await store.upsert(canvas)
                        canvases = await store.allCanvases()
                    }
                case .finalCanvas(let final):
                    var updated = final
                    updated.modelTag = selectedModelTag
                    try? await store.upsert(updated)
                    selectedCanvasID = updated.id
                case .usage(let usage):
                    lastInvestigationUsage = usage
                case .toolCall, .toolResult:
                    break
                }
            }
            canvases = await store.allCanvases()
            await refreshSelectedCanvasData()
        } catch {
            composerError = error.localizedDescription
        }
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
