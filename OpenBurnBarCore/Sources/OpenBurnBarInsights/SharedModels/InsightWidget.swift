import Foundation

/// A single widget on a canvas.
///
/// `spec`, `dataBinding`, and the cached `data` together let the widget
/// render instantly from disk (last-known data) and refresh asynchronously
/// when the canvas opens.
public struct InsightWidget: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: InsightWidgetKind
    public var title: String
    public var subtitle: String?
    public var spec: InsightWidgetSpec
    public var dataBinding: InsightDataBinding
    /// Cached data so the widget can render instantly when the canvas opens.
    /// Refreshed asynchronously via `InsightExecutor`.
    public var data: InsightWidgetData?
    public var filter: InsightFilter?
    public var freshness: InsightFreshness
    public var modelTag: InsightModelTag?
    public var lockedAt: Date?
    public var lastComputedAt: Date?
    public var schemaVersion: Int
    public var rationale: String?

    public static let currentSchemaVersion = 1

    public init(
        id: UUID = UUID(),
        kind: InsightWidgetKind,
        title: String,
        subtitle: String? = nil,
        spec: InsightWidgetSpec,
        dataBinding: InsightDataBinding,
        data: InsightWidgetData? = nil,
        filter: InsightFilter? = nil,
        freshness: InsightFreshness = .stale,
        modelTag: InsightModelTag? = nil,
        lockedAt: Date? = nil,
        lastComputedAt: Date? = nil,
        schemaVersion: Int = InsightWidget.currentSchemaVersion,
        rationale: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.spec = spec
        self.dataBinding = dataBinding
        self.data = data
        self.filter = filter
        self.freshness = freshness
        self.modelTag = modelTag
        self.lockedAt = lockedAt
        self.lastComputedAt = lastComputedAt
        self.schemaVersion = schemaVersion
        self.rationale = rationale
    }
}
