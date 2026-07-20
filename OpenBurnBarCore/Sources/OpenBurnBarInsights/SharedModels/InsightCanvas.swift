import Foundation

/// A persistent dashboard composed of insight widgets.
///
/// The user can have many canvases (saved boards) and switch between them
/// from the canvas library. Each canvas survives sync, export/import, and
/// schema evolution via `schemaVersion`.
public struct InsightCanvas: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion: Int = 1

    public let id: UUID
    public var title: String
    public var summary: String?
    public var symbolName: String
    public var theme: InsightTheme
    public var widgets: [InsightWidget]
    public var layout: InsightLayout
    public var filter: InsightFilter
    public var modelTag: InsightModelTag?
    public var schemaVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRefreshedAt: Date?
    public var origin: Origin
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String? = nil,
        symbolName: String = "sparkles.tv",
        theme: InsightTheme = .aurora,
        widgets: [InsightWidget] = [],
        layout: InsightLayout = InsightLayout(),
        filter: InsightFilter = InsightFilter(),
        modelTag: InsightModelTag? = nil,
        schemaVersion: Int = InsightCanvas.currentSchemaVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastRefreshedAt: Date? = nil,
        origin: Origin = .userCreated,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.theme = theme
        self.widgets = widgets
        self.layout = layout
        self.filter = filter
        self.modelTag = modelTag
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.origin = origin
        self.sortIndex = sortIndex
    }

    public enum Origin: Codable, Hashable, Sendable {
        case userCreated
        case template(id: String)
        case composed(prompt: String)
        case imported(filename: String)
    }

    // MARK: - Mutations

    /// Add a widget and place it on the layout at the first available cell.
    public mutating func add(_ widget: InsightWidget) {
        widgets.append(widget)
        layout.placeNew(widgetID: widget.id, defaultSpan: widget.kind.defaultSpan)
        updatedAt = Date()
    }

    /// Remove a widget by id from both the array and the layout.
    public mutating func remove(widgetID: UUID) {
        widgets.removeAll { $0.id == widgetID }
        layout.remove(widgetID: widgetID)
        updatedAt = Date()
    }

    /// Replace a widget while preserving its identity and layout placement.
    public mutating func replace(_ widget: InsightWidget) {
        guard let idx = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[idx] = widget
        updatedAt = Date()
    }

    /// Update a single widget in place.
    public mutating func update(widgetID: UUID, _ mutate: (inout InsightWidget) -> Void) {
        guard let idx = widgets.firstIndex(where: { $0.id == widgetID }) else { return }
        var w = widgets[idx]
        mutate(&w)
        widgets[idx] = w
        updatedAt = Date()
    }
}
