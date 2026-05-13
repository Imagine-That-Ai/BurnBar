import XCTest
@testable import OpenBurnBarCore

final class InsightFoundationTests: XCTestCase {

    // MARK: - Codecs

    func testCanvasCodecRoundTrip() throws {
        var canvas = InsightCanvas(
            title: "Test Canvas",
            summary: "round-trip",
            symbolName: "sparkles",
            theme: .ember
        )
        let widget = InsightWidget(
            kind: .kpiTile,
            title: "Cost",
            spec: .kpiTile(.init(metricLabel: "Cost")),
            dataBinding: .kpi(metric: .totalCost, window: .last7d)
        )
        canvas.add(widget)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canvas)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(InsightCanvas.self, from: data)

        XCTAssertEqual(restored.id, canvas.id)
        XCTAssertEqual(restored.title, canvas.title)
        XCTAssertEqual(restored.theme, .ember)
        XCTAssertEqual(restored.widgets.count, 1)
        XCTAssertEqual(restored.widgets.first?.kind, .kpiTile)
        XCTAssertEqual(restored.layout.placements.count, 1)
    }

    func testEveryWidgetKindRoundTrips() throws {
        // Per the architecture doc: a widget is the smallest unit of
        // composition. Every kind must serialize/deserialize cleanly so
        // canvases survive sync and export.
        for kind in InsightWidgetKind.allCases {
            let widget = InsightWidget(
                kind: kind,
                title: "Test \(kind.displayName)",
                spec: representativeSpec(for: kind),
                dataBinding: representativeBinding(for: kind)
            )
            let data = try JSONEncoder().encode(widget)
            let restored = try JSONDecoder().decode(InsightWidget.self, from: data)
            XCTAssertEqual(restored.kind, kind, "Widget kind \(kind) failed round-trip")
            XCTAssertEqual(restored.id, widget.id)
        }
    }

    private func representativeSpec(for kind: InsightWidgetKind) -> InsightWidgetSpec {
        switch kind {
        case .kpiTile: return .kpiTile(.init(metricLabel: "Cost"))
        case .timeSeriesLine: return .timeSeries(.init(style: .line))
        case .timeSeriesArea: return .timeSeries(.init(style: .area))
        case .streamGraph: return .timeSeries(.init(style: .stream))
        case .barRanking: return .ranking(.init())
        case .donut: return .distribution(.init(style: .donut))
        case .treemap: return .distribution(.init(style: .treemap))
        case .heatmap: return .heatmap(.init())
        case .scatter: return .scatter(.init())
        case .sankey: return .sankey(.init())
        case .radar: return .radar(.init())
        case .cohort: return .cohort(.init())
        case .funnel: return .funnel(.init())
        case .quotaPulse: return .quotaPulse(.init())
        case .forecast: return .forecast(.init())
        case .anomalyTable: return .anomalyTable(.init())
        case .narrative: return .narrative(.init())
        case .recommendation: return .recommendation(.init())
        case .useCaseCluster: return .useCaseCluster(.init())
        case .agentFocusMatrix: return .agentFocusMatrix(.init())
        case .modelFocusMatrix: return .modelFocusMatrix(.init())
        case .drilldownList: return .drilldownList(.init())
        case .mermaid: return .mermaid(.init())
        case .ascii: return .ascii(.init())
        case .composed: return .composed(.init(children: [.kpiTile(.init(metricLabel: "x"))]))
        case .error: return .error(.init(message: "test"))
        }
    }

    private func representativeBinding(for kind: InsightWidgetKind) -> InsightDataBinding {
        switch kind {
        case .kpiTile: return .kpi(metric: .totalCost, window: .last7d)
        case .timeSeriesLine, .timeSeriesArea, .streamGraph:
            return .timeSeries(metric: .cost, dimension: .provider, window: .last30d)
        case .barRanking: return .ranking(metric: .cost, dimension: .model, limit: 10, window: .last30d)
        case .donut: return .distribution(metric: .cost, dimension: .provider, window: .last30d)
        case .treemap: return .distribution(metric: .cost, dimension: .model, window: .last30d)
        case .heatmap: return .heatmap(metric: .sessions, window: .last30d)
        case .scatter: return .scatter(xMetric: .tokens, yMetric: .cost, dimension: .model, window: .last30d)
        case .sankey: return .sankey(source: .provider, mid: nil, target: .model, window: .last30d)
        case .radar: return .radar(target: .allAgents, window: .last30d)
        case .cohort: return .cohort(window: .last90d)
        case .funnel: return .funnel(stages: ["start", "tool_call", "complete"], window: .last30d)
        case .quotaPulse: return .quota(providerKey: nil)
        case .forecast: return .forecast(metric: .cost, horizonDays: 7)
        case .anomalyTable: return .anomaly(window: .last90d)
        case .narrative: return .narrative(.init(headline: "Hello", body: "World"))
        case .recommendation: return .recommendation(.init(headline: "h", rationale: "r", action: "a"))
        case .useCaseCluster: return .useCaseClusters(window: .last30d)
        case .agentFocusMatrix: return .agentFocusMatrix(window: .last30d)
        case .modelFocusMatrix: return .modelFocusMatrix(window: .last30d)
        case .drilldownList: return .drilldown(limit: 10)
        case .mermaid: return .mermaid(source: "graph TD; A-->B")
        case .ascii: return .ascii(.init(headline: "h", monoBody: "##"))
        case .composed: return .composed([.kpi(metric: .totalCost, window: .last7d)])
        case .error: return .narrative(.init(headline: "Err", body: "see message"))
        }
    }

    // MARK: - Layout

    func testLayoutPlaceNewFillsFirstFreeCell() {
        var layout = InsightLayout()
        let a = UUID(), b = UUID()
        layout.placeNew(widgetID: a, defaultSpan: (4, 2))
        layout.placeNew(widgetID: b, defaultSpan: (4, 2))
        XCTAssertEqual(layout.placements[a]?.column, 0)
        XCTAssertEqual(layout.placements[a]?.row, 0)
        XCTAssertEqual(layout.placements[b]?.column, 4)
        XCTAssertEqual(layout.placements[b]?.row, 0)
        XCTAssertGreaterThanOrEqual(layout.revision, 2)
    }

    func testLayoutProjectionPreservesContentAndAvoidsOverlap() {
        var layout = InsightLayout(columnCount: 12)
        for _ in 0..<8 {
            layout.placeNew(widgetID: UUID(), defaultSpan: (4, 2))
        }
        let projected = layout.projected(toColumnCount: 6)
        XCTAssertEqual(projected.columnCount, 6)
        XCTAssertEqual(projected.placements.count, layout.placements.count)
        // No overlaps in the projection.
        var grid: Set<String> = []
        for (_, p) in projected.placements {
            for r in p.row..<(p.row + p.rowSpan) {
                for c in p.column..<(p.column + p.colSpan) {
                    let key = "\(r):\(c)"
                    XCTAssertFalse(grid.contains(key), "Overlap at \(key)")
                    grid.insert(key)
                }
            }
        }
        // All projected widgets fit inside 6 cols.
        for (_, p) in projected.placements {
            XCTAssertLessThanOrEqual(p.column + p.colSpan, 6)
        }
    }

    func testLayoutResizeClampsToColumnCount() {
        var layout = InsightLayout(columnCount: 12)
        let id = UUID()
        layout.placeNew(widgetID: id, defaultSpan: (4, 2))
        layout.resize(widgetID: id, colSpan: 30, rowSpan: 5)
        XCTAssertEqual(layout.placements[id]?.colSpan, 12)
        XCTAssertEqual(layout.placements[id]?.rowSpan, 5)
    }

    // MARK: - Filter

    func testTimeWindowIntervalsArePositive() {
        let now = Date()
        for window: InsightTimeWindow in [.today, .last24h, .last7d, .last30d, .last90d, .last365d, .allTime] {
            let interval = window.interval(now: now)
            XCTAssertGreaterThan(interval.end, interval.start, "Window \(window) had non-positive interval")
        }
    }

    func testFilterOverlayPrefersWidgetValues() {
        let base = InsightFilter(window: .last30d, providers: ["A"])
        let widget = InsightFilter(window: .last7d, providers: ["B"])
        let merged = base.overlaid(by: widget)
        XCTAssertEqual(merged.window, .last7d)
        XCTAssertEqual(merged.providers, ["B"])
    }

    // MARK: - Theme + freshness enums

    func testThemesAreExhaustive() {
        // Compile-time: every theme has a non-empty display name.
        for theme in InsightTheme.allCases {
            XCTAssertFalse(theme.displayName.isEmpty)
            XCTAssertFalse(theme.symbolName.isEmpty)
        }
    }

    func testFreshnessRoundTrips() throws {
        for f in InsightFreshness.allCases {
            let data = try JSONEncoder().encode(f)
            let restored = try JSONDecoder().decode(InsightFreshness.self, from: data)
            XCTAssertEqual(restored, f)
        }
    }

    func testTaxonomyMembership() {
        XCTAssertTrue(InsightTaxonomy.default.isKnownFocus("code"))
        XCTAssertFalse(InsightTaxonomy.default.isKnownFocus("nope"))
        XCTAssertTrue(InsightTaxonomy.default.isKnownUseCase("bug-fix"))
    }

    // MARK: - Template instantiation

    func testTemplateInstantiationGeneratesFreshIDs() {
        let template = InsightCanvasTemplate(
            id: "test",
            title: "T",
            summary: "S",
            symbolName: "sparkles",
            theme: .aurora,
            widgets: [.init(kind: .kpiTile, title: "C",
                            spec: .kpiTile(.init(metricLabel: "Cost")),
                            dataBinding: .kpi(metric: .totalCost, window: .last7d))],
            layout: InsightLayout(),
            filter: InsightFilter()
        )
        let a = template.instantiate()
        let b = template.instantiate()
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.widgets.first?.id, b.widgets.first?.id)
        XCTAssertEqual(a.origin, .template(id: "test"))
    }

    func testTemplateInstantiationAutoPlacesWidgetsWithoutPlacements() {
        // Regression: previously the template's empty layout produced
        // canvases where every widget was placed at origin with zero size.
        // `instantiate()` must auto-place anything that lacks a placement.
        let template = InsightCanvasTemplate(
            id: "auto-place",
            title: "AutoPlace",
            summary: "—",
            symbolName: "sparkles",
            theme: .aurora,
            widgets: [
                .init(kind: .kpiTile, title: "A",
                      spec: .kpiTile(.init(metricLabel: "A")),
                      dataBinding: .kpi(metric: .totalCost, window: .last7d)),
                .init(kind: .donut, title: "B",
                      spec: .distribution(.init(style: .donut)),
                      dataBinding: .distribution(metric: .cost, dimension: .provider, window: .last7d)),
                .init(kind: .narrative, title: "C",
                      spec: .narrative(.init()),
                      dataBinding: .narrative(.init(headline: "h", body: "b")))
            ],
            layout: InsightLayout(columnCount: 12),
            filter: InsightFilter()
        )
        let canvas = template.instantiate()
        XCTAssertEqual(canvas.widgets.count, 3)
        XCTAssertEqual(canvas.layout.placements.count, 3)
        for widget in canvas.widgets {
            let placement = canvas.layout.placements[widget.id]
            XCTAssertNotNil(placement, "Widget \(widget.title) lacks a placement")
            XCTAssertGreaterThan(placement?.colSpan ?? 0, 0)
            XCTAssertGreaterThan(placement?.rowSpan ?? 0, 0)
        }
        // No overlaps.
        var occupied: Set<String> = []
        for placement in canvas.layout.placements.values {
            for r in placement.row..<(placement.row + placement.rowSpan) {
                for c in placement.column..<(placement.column + placement.colSpan) {
                    let key = "\(r):\(c)"
                    XCTAssertFalse(occupied.contains(key), "Overlap at \(key)")
                    occupied.insert(key)
                }
            }
        }
        // Canvas rowCount must be positive — otherwise the grid renders at zero height.
        XCTAssertGreaterThan(canvas.layout.rowCount, 0)
    }
}
