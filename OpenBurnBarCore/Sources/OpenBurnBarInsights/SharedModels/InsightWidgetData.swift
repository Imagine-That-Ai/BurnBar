import Foundation

/// Concrete value-typed data shape that renderers actually consume.
///
/// Produced by `InsightExecutor` from an `InsightDataBinding` (deterministic
/// local data) or by the LLM gateway (narrative / recommendation). Once a
/// renderer is reading `InsightWidgetData`, it never reaches back into the
/// store — that's what makes widgets reorderable, exportable, and
/// snapshot-able.
public enum InsightWidgetData: Codable, Hashable, Sendable {
    case kpi(KPI)
    case timeSeries(TimeSeries)
    case ranking(Ranking)
    case distribution(Distribution)
    case heatmap(Heatmap)
    case scatter(Scatter)
    case sankey(Sankey)
    case radar(Radar)
    case cohort(Cohort)
    case funnel(Funnel)
    case quota(QuotaState)
    case forecast(Forecast)
    case anomaly(AnomalyTable)
    case narrative(Narrative)
    case recommendation(Recommendation)
    case useCaseCluster(UseCaseCluster)
    case focusMatrix(FocusMatrix)
    case drilldown(Drilldown)
    case mermaid(String)
    case ascii(ASCIICard)
    case composed([InsightWidgetData])
    case empty(reason: String)
    case error(message: String)

    // MARK: - Variants

    public struct KPI: Codable, Hashable, Sendable {
        public var metricLabel: String
        public var value: Double
        public var valueFormat: ValueFormat
        public var delta: Double?
        public var deltaIsPercent: Bool
        public var sparkline: [Double]
        public var contextLabel: String?
        public init(metricLabel: String, value: Double, valueFormat: ValueFormat,
                    delta: Double? = nil, deltaIsPercent: Bool = true,
                    sparkline: [Double] = [], contextLabel: String? = nil) {
            self.metricLabel = metricLabel
            self.value = value
            self.valueFormat = valueFormat
            self.delta = delta
            self.deltaIsPercent = deltaIsPercent
            self.sparkline = sparkline
            self.contextLabel = contextLabel
        }
    }

    public struct TimeSeries: Codable, Hashable, Sendable {
        public var series: [Series]
        public var xAxisLabel: String
        public var yAxisLabel: String
        public var yFormat: ValueFormat
        public var annotations: [Annotation]
        public init(series: [Series], xAxisLabel: String, yAxisLabel: String,
                    yFormat: ValueFormat, annotations: [Annotation] = []) {
            self.series = series
            self.xAxisLabel = xAxisLabel
            self.yAxisLabel = yAxisLabel
            self.yFormat = yFormat
            self.annotations = annotations
        }
        public struct Series: Codable, Hashable, Sendable, Identifiable {
            public let id: String
            public var name: String
            public var colorHex: String?
            public var points: [Point]
            public init(id: String, name: String, colorHex: String? = nil, points: [Point]) {
                self.id = id; self.name = name; self.colorHex = colorHex; self.points = points
            }
        }
        public struct Point: Codable, Hashable, Sendable {
            public var date: Date
            public var value: Double
            public init(date: Date, value: Double) { self.date = date; self.value = value }
        }
        public struct Annotation: Codable, Hashable, Sendable {
            public var date: Date
            public var label: String
            public var tone: Tone
            public init(date: Date, label: String, tone: Tone) {
                self.date = date; self.label = label; self.tone = tone
            }
            public enum Tone: String, Codable, Hashable, Sendable {
                case positive, neutral, warning, negative
            }
        }
    }

    public struct Ranking: Codable, Hashable, Sendable {
        public var rows: [Row]
        public var valueFormat: ValueFormat
        public var dimensionLabel: String
        public init(rows: [Row], valueFormat: ValueFormat, dimensionLabel: String) {
            self.rows = rows; self.valueFormat = valueFormat; self.dimensionLabel = dimensionLabel
        }
        public struct Row: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var value: Double
            public var secondaryLabel: String?
            public var colorHex: String?
            public init(id: String, label: String, value: Double,
                        secondaryLabel: String? = nil, colorHex: String? = nil) {
                self.id = id; self.label = label; self.value = value
                self.secondaryLabel = secondaryLabel; self.colorHex = colorHex
            }
        }
    }

    public struct Distribution: Codable, Hashable, Sendable {
        public var slices: [Slice]
        public var valueFormat: ValueFormat
        public var total: Double
        public init(slices: [Slice], valueFormat: ValueFormat, total: Double) {
            self.slices = slices; self.valueFormat = valueFormat; self.total = total
        }
        public struct Slice: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var value: Double
            public var colorHex: String?
            public init(id: String, label: String, value: Double, colorHex: String? = nil) {
                self.id = id; self.label = label; self.value = value; self.colorHex = colorHex
            }
        }
    }

    public struct Heatmap: Codable, Hashable, Sendable {
        /// 7 (rows = day-of-week) × 24 (cols = hour) by default but encoded generically.
        public var rowLabels: [String]
        public var columnLabels: [String]
        public var cells: [[Double]]
        public var valueFormat: ValueFormat
        public init(rowLabels: [String], columnLabels: [String], cells: [[Double]], valueFormat: ValueFormat) {
            self.rowLabels = rowLabels; self.columnLabels = columnLabels
            self.cells = cells; self.valueFormat = valueFormat
        }
    }

    public struct Scatter: Codable, Hashable, Sendable {
        public var points: [Point]
        public var xAxisLabel: String
        public var yAxisLabel: String
        public var xFormat: ValueFormat
        public var yFormat: ValueFormat
        public init(points: [Point], xAxisLabel: String, yAxisLabel: String,
                    xFormat: ValueFormat, yFormat: ValueFormat) {
            self.points = points; self.xAxisLabel = xAxisLabel; self.yAxisLabel = yAxisLabel
            self.xFormat = xFormat; self.yFormat = yFormat
        }
        public struct Point: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var x: Double
            public var y: Double
            public var size: Double
            public var colorHex: String?
            public init(id: String, label: String, x: Double, y: Double,
                        size: Double = 1, colorHex: String? = nil) {
                self.id = id; self.label = label; self.x = x; self.y = y
                self.size = size; self.colorHex = colorHex
            }
        }
    }

    public struct Sankey: Codable, Hashable, Sendable {
        public var nodes: [Node]
        public var links: [Link]
        public init(nodes: [Node], links: [Link]) {
            self.nodes = nodes; self.links = links
        }
        public struct Node: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var colorHex: String?
            public init(id: String, label: String, colorHex: String? = nil) {
                self.id = id; self.label = label; self.colorHex = colorHex
            }
        }
        public struct Link: Codable, Hashable, Sendable, Identifiable {
            public var id: String { "\(source)→\(target)" }
            public var source: String
            public var target: String
            public var value: Double
            public init(source: String, target: String, value: Double) {
                self.source = source; self.target = target; self.value = value
            }
        }
    }

    public struct Radar: Codable, Hashable, Sendable {
        public var axes: [String]
        public var series: [Series]
        public init(axes: [String], series: [Series]) {
            self.axes = axes; self.series = series
        }
        public struct Series: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var values: [Double]    // count == axes.count
            public var colorHex: String?
            public init(id: String, name: String, values: [Double], colorHex: String? = nil) {
                self.id = id; self.name = name; self.values = values; self.colorHex = colorHex
            }
        }
    }

    public struct Cohort: Codable, Hashable, Sendable {
        public var cohortLabels: [String]
        public var periodLabels: [String]
        public var cells: [[Double?]]
        public init(cohortLabels: [String], periodLabels: [String], cells: [[Double?]]) {
            self.cohortLabels = cohortLabels; self.periodLabels = periodLabels; self.cells = cells
        }
    }

    public struct Funnel: Codable, Hashable, Sendable {
        public var steps: [Step]
        public init(steps: [Step]) { self.steps = steps }
        public struct Step: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var count: Double
            public init(id: String, label: String, count: Double) {
                self.id = id; self.label = label; self.count = count
            }
        }
    }

    public struct QuotaState: Codable, Hashable, Sendable {
        public var buckets: [Bucket]
        public init(buckets: [Bucket]) { self.buckets = buckets }
        public struct Bucket: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var providerLabel: String
            public var bucketName: String
            public var used: Double
            public var limit: Double?
            public var resetsAt: Date?
            public var symbolName: String
            public var colorHex: String?
            public init(id: String, providerLabel: String, bucketName: String,
                        used: Double, limit: Double?, resetsAt: Date?,
                        symbolName: String, colorHex: String? = nil) {
                self.id = id; self.providerLabel = providerLabel; self.bucketName = bucketName
                self.used = used; self.limit = limit; self.resetsAt = resetsAt
                self.symbolName = symbolName; self.colorHex = colorHex
            }
            public var fraction: Double {
                guard let limit, limit > 0 else { return 0 }
                return min(1, max(0, used / limit))
            }
        }
    }

    public struct Forecast: Codable, Hashable, Sendable {
        public var actual: [TimeSeries.Point]
        public var forecast: [TimeSeries.Point]
        public var lowerBound: [TimeSeries.Point]
        public var upperBound: [TimeSeries.Point]
        public var xAxisLabel: String
        public var yAxisLabel: String
        public var yFormat: ValueFormat
        public var summary: String?
        public init(actual: [TimeSeries.Point], forecast: [TimeSeries.Point],
                    lowerBound: [TimeSeries.Point], upperBound: [TimeSeries.Point],
                    xAxisLabel: String, yAxisLabel: String, yFormat: ValueFormat,
                    summary: String? = nil) {
            self.actual = actual; self.forecast = forecast
            self.lowerBound = lowerBound; self.upperBound = upperBound
            self.xAxisLabel = xAxisLabel; self.yAxisLabel = yAxisLabel
            self.yFormat = yFormat; self.summary = summary
        }
    }

    public struct AnomalyTable: Codable, Hashable, Sendable {
        public var rows: [Row]
        public init(rows: [Row]) { self.rows = rows }
        public struct Row: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var occurredAt: Date
            public var label: String
            public var detail: String?
            public var score: Double
            public var citations: [InsightCitation]
            public init(id: String, occurredAt: Date, label: String, detail: String?,
                        score: Double, citations: [InsightCitation] = []) {
                self.id = id; self.occurredAt = occurredAt; self.label = label
                self.detail = detail; self.score = score; self.citations = citations
            }
        }
    }

    public struct Narrative: Codable, Hashable, Sendable {
        public var headline: String
        public var body: String
        public var bullets: [String]
        public var tone: Tone
        public var citations: [InsightCitation]
        public var sparkline: [Double]
        public init(headline: String, body: String, bullets: [String] = [],
                    tone: Tone = .neutral, citations: [InsightCitation] = [],
                    sparkline: [Double] = []) {
            self.headline = headline; self.body = body; self.bullets = bullets
            self.tone = tone; self.citations = citations; self.sparkline = sparkline
        }
        public enum Tone: String, Codable, Hashable, Sendable, CaseIterable {
            case positive, neutral, warning, negative
        }
    }

    public struct Recommendation: Codable, Hashable, Sendable {
        public var headline: String
        public var rationale: String
        public var action: String
        public var estimatedImpact: String?
        public var confidence: Confidence
        public var citations: [InsightCitation]
        public init(headline: String, rationale: String, action: String,
                    estimatedImpact: String? = nil, confidence: Confidence = .medium,
                    citations: [InsightCitation] = []) {
            self.headline = headline; self.rationale = rationale; self.action = action
            self.estimatedImpact = estimatedImpact; self.confidence = confidence
            self.citations = citations
        }
        public enum Confidence: String, Codable, Hashable, Sendable, CaseIterable {
            case low, medium, high
        }
    }

    public struct UseCaseCluster: Codable, Hashable, Sendable {
        public var clusters: [Cluster]
        public init(clusters: [Cluster]) { self.clusters = clusters }
        public struct Cluster: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var size: Int
            public var exampleSessionIDs: [String]
            public var colorHex: String?
            public init(id: String, label: String, size: Int,
                        exampleSessionIDs: [String] = [], colorHex: String? = nil) {
                self.id = id; self.label = label; self.size = size
                self.exampleSessionIDs = exampleSessionIDs; self.colorHex = colorHex
            }
        }
    }

    public struct FocusMatrix: Codable, Hashable, Sendable {
        public var rowLabels: [String]      // agents or models
        public var columnLabels: [String]   // taxonomy focuses
        public var cells: [[Double]]        // weights 0…1
        public init(rowLabels: [String], columnLabels: [String], cells: [[Double]]) {
            self.rowLabels = rowLabels; self.columnLabels = columnLabels; self.cells = cells
        }
    }

    public struct Drilldown: Codable, Hashable, Sendable {
        public var rows: [Row]
        public init(rows: [Row]) { self.rows = rows }
        public struct Row: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var title: String
            public var subtitle: String?
            public var occurredAt: Date
            public var costUSD: Double?
            public var tokens: Int?
            public var citation: InsightCitation
            public init(id: String, title: String, subtitle: String? = nil,
                        occurredAt: Date, costUSD: Double? = nil, tokens: Int? = nil,
                        citation: InsightCitation) {
                self.id = id; self.title = title; self.subtitle = subtitle
                self.occurredAt = occurredAt; self.costUSD = costUSD
                self.tokens = tokens; self.citation = citation
            }
        }
    }

    public struct ASCIICard: Codable, Hashable, Sendable {
        public var headline: String
        public var monoBody: String
        public var caption: String?
        public init(headline: String, monoBody: String, caption: String? = nil) {
            self.headline = headline; self.monoBody = monoBody; self.caption = caption
        }
    }
}

/// Format hint used by renderers when displaying numeric values.
public enum ValueFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case currency
    case tokens
    case percent
    case duration
    case count
    case raw
}
