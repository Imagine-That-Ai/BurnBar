import SwiftUI
import OpenBurnBarCore

// MARK: - Source Filter

// The filter/group enums and `SessionLogGroup` are internal (not private) so
// `SessionLogGroupsCacheTests` can drive the pure compute functions below.
enum SessionLogSourceFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case provider = "Provider"
    case assistant = "Assistant"
    var id: String { rawValue }
}

// MARK: - Group Mode

enum SessionLogGroupMode: String, CaseIterable, Identifiable {
    case time = "Time"
    case provider = "Provider"
    case project = "Project"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .time: return "clock"
        case .provider: return "cpu"
        case .project: return "folder"
        }
    }
}

// MARK: - Data Source

enum SessionLogDataSource: String, CaseIterable, Identifiable {
    case local  = "Local"
    case cloud  = "Cloud"
    case iCloud = "iCloud"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .local:  return "internaldrive"
        case .cloud:  return "cloud"
        case .iCloud: return "icloud"
        }
    }
}

// MARK: - Session Log Group

struct SessionLogGroup: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let accentColor: Color
    let provider: AgentProvider?
    let logs: [ConversationRecord]
}
