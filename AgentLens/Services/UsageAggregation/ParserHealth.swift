import Foundation

enum ParserHealth {
    case healthy(sessionCount: Int)
    case empty
    case degraded(sessionCount: Int, error: String)
    case failed(error: String)
    case notConfigured
}

extension ParserHealth {
    var statusLabel: String {
        switch self {
        case .healthy:
            return "healthy"
        case .empty:
            return "empty"
        case .degraded:
            return "degraded"
        case .failed:
            return "failed"
        case .notConfigured:
            return "not_configured"
        }
    }

    var sessionCount: Int {
        switch self {
        case .healthy(let count), .degraded(let count, _):
            return max(0, count)
        case .empty, .failed, .notConfigured:
            return 0
        }
    }

    var errorMessage: String? {
        switch self {
        case .degraded(_, let error):
            return error
        case .failed(let error):
            return error
        case .healthy, .empty, .notConfigured:
            return nil
        }
    }
}
