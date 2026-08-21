import Foundation

// MARK: - Dashboard Sidebar Sections
//
// Reorderable, customizable sections for the Dashboard sidebar.
// Follows the `DashboardHomeRailPanel` codec pattern from `DashboardHomeModes.swift`:
// comma-separated raw values persisted via `@AppStorage`, normalized against
// `allCases` (decoded ∩ available, then append missing available cases, drop unknown).

enum DashboardSidebarSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case providers
    case models
    case projects
    case sessions
    case quota
    case fleet
    case inbox

    var id: String { rawValue }

    static let orderStorageKey = "dashboard.sidebar.sectionOrder"
    static let stateStorageKey = "dashboard.sidebar.sectionState"

    static let defaultOrder: [DashboardSidebarSection] = [
        .providers,
        .models,
        .projects,
        .sessions,
        .quota,
        .fleet,
        .inbox
    ]

    var title: String {
        switch self {
        case .providers: return "PROVIDERS"
        case .models:    return "MODELS"
        case .projects:  return "PROJECTS"
        case .sessions:  return "SESSIONS"
        case .quota:     return "QUOTA"
        case .fleet:     return "FLEET"
        case .inbox:     return "INBOX"
        }
    }

    var displayName: String {
        switch self {
        case .providers: return "Agent Providers"
        case .models:    return "LLM Models"
        case .projects:  return "Projects"
        case .sessions:  return "Recent Sessions"
        case .quota:     return "Quota & Limits"
        case .fleet:     return "Live Fleet"
        case .inbox:     return "AI Inbox"
        }
    }

    var symbolName: String {
        switch self {
        case .providers: return "cpu"
        case .models:    return "cube"
        case .projects:  return "folder"
        case .sessions:  return "text.bubble"
        case .quota:     return "gauge.with.dots.needle.67percent"
        case .fleet:     return "antenna.radiowaves.left.and.right"
        case .inbox:     return "tray.full"
        }
    }

    var accessibilityLabel: String {
        displayName
    }

    /// Decodes the persisted order, normalized against what actually exists.
    ///
    /// Same shape as `DashboardHomeRailPanel.ordered(from:)`: decoded ∩
    /// available, then append any available that were not stored. That makes a
    /// future section appear automatically and an unknown/stale key harmlessly dropped.
    static func ordered(from raw: String) -> [DashboardSidebarSection] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allCases }
        let decoded = trimmed
            .split(separator: ",")
            .compactMap { DashboardSidebarSection(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        var result = decoded.filter { allCases.contains($0) }
        for section in allCases where !result.contains(section) {
            result.append(section)
        }
        return result
    }

    static func encode(_ sections: [DashboardSidebarSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Pure reordering helper for unit testing and view mutations.
    static func moveSection(
        _ section: DashboardSidebarSection,
        by offset: Int,
        in order: [DashboardSidebarSection]
    ) -> [DashboardSidebarSection] {
        var copy = order
        guard let index = copy.firstIndex(of: section) else { return order }
        let target = index + offset
        guard copy.indices.contains(target) else { return order }
        copy.swapAt(index, target)
        return copy
    }
}

/// Per-section persisted state (e.g. collapsed or hidden).
struct DashboardSidebarSectionState: Codable, Equatable {
    var collapsed: Bool = false
    var isVisible: Bool = true

    static func decode(_ raw: String) -> [String: DashboardSidebarSectionState] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: DashboardSidebarSectionState].self, from: data)
        else { return [:] }
        return decoded
    }

    static func encode(_ state: [String: DashboardSidebarSectionState]) -> String {
        guard let data = try? JSONEncoder().encode(state),
              let raw = String(data: data, encoding: .utf8)
        else { return "{}" }
        return raw
    }

    static func toggleCollapsed(
        _ section: DashboardSidebarSection,
        in state: [String: DashboardSidebarSectionState]
    ) -> [String: DashboardSidebarSectionState] {
        var copy = state
        var entry = copy[section.rawValue] ?? DashboardSidebarSectionState()
        entry.collapsed.toggle()
        copy[section.rawValue] = entry
        return copy
    }

    static func toggleVisibility(
        _ section: DashboardSidebarSection,
        in state: [String: DashboardSidebarSectionState]
    ) -> [String: DashboardSidebarSectionState] {
        var copy = state
        var entry = copy[section.rawValue] ?? DashboardSidebarSectionState()
        entry.isVisible.toggle()
        copy[section.rawValue] = entry
        return copy
    }
}
