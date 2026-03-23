import Foundation

// MARK: - Search Result

struct SearchResult: Identifiable {
    var id: String { conversation.id }
    let conversation: ConversationRecord
    let snippet: String
    let rank: Double
}

// MARK: - Search Service

@MainActor
final class SearchService {
    private let dataStore: DataStore

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    func search(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) async -> [SearchResult] {
        (try? dataStore.searchConversationsFTS(
            query: query,
            provider: provider,
            projectName: projectName,
            dateRange: dateRange
        )) ?? []
    }
}
