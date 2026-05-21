import Foundation

/// One row in the "Recent Transfers" list. Both sent and received
/// transfers persist with this shape so the UI can render a unified
/// timeline. `localURL` is nil for sent rows (the user picked a file
/// outside our sandbox); received rows always have a path under
/// `~/Library/Caches/Mercury/MediaInbox/`.
struct MercuryTransferHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let connectionID: String
    let direction: Direction
    let filename: String
    let mime: String?
    let sizeBytes: Int64
    let completedAt: Date
    let bytesPerSecond: Double?
    let didResume: Bool
    let localURL: URL?

    enum Direction: String, Codable, Equatable, Sendable {
        case sent
        case received

        var displayName: String {
            switch self {
            case .sent:     return "Sent"
            case .received: return "Received"
            }
        }

        var arrowIcon: String {
            switch self {
            case .sent:     return "arrow.up.right.circle.fill"
            case .received: return "arrow.down.left.circle.fill"
            }
        }
    }

    /// True when the manifest MIME indicates an image — drives the
    /// optional thumbnail rendering in `MercuryRecentTransfersCard`.
    var looksLikeImage: Bool {
        guard let mime else { return false }
        return mime.lowercased().hasPrefix("image/")
    }
}
