import Foundation

/// Lifecycle state of an individual widget's data.
///
/// Surfaced as a small pill in the widget header so the user always knows
/// whether they're looking at live numbers, a cached snapshot, or a
/// pinned-in-time view authored by the LLM.
public enum InsightFreshness: String, Codable, Hashable, Sendable, CaseIterable {
    /// Data is current as of the last refresh.
    case fresh
    /// Source data has moved on since the widget was computed.
    case stale
    /// A local executor or LLM is actively (re)computing this widget.
    case computing
    /// The widget failed to compute. The error message lives on the widget data.
    case error
    /// The user pinned a snapshot — refresh is suppressed until unpinned.
    case locked
}
