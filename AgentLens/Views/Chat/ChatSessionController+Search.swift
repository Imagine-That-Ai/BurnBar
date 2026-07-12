import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

// Sidebar search.
// Extracted from ChatSessionController.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ChatSessionController {

    func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            cancelCurrentSearch(clearResults: true)
            refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
            return
        }

        if isSearching, activeSearchQuery == q {
            return
        }

        cancelCurrentSearch(clearResults: false)
        let requestID = nextSearchRequestID()
        let queryRevisionAtStart = searchQueryRevision
        activeSearchQuery = q
        isSearching = true
        Analytics.shared.track(.chatSearchPerformed, [
            "query_length": .string(AnalyticsBuckets.count(q.count))
        ])
        let service = searchService
        searchTask = Task { [service] in
            let results = await service.search(query: q)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.activeSearchRequestID == requestID,
                      self.searchQueryRevision == queryRevisionAtStart,
                      self.normalizedSearchQuery() == q else {
                    if self.activeSearchRequestID == requestID {
                        self.searchTask = nil
                    }
                    return
                }

                self.searchResults = results
                self.isSearching = false
                self.searchTask = nil
                self.refreshRetrievalHealth(sharedFeaturesAvailable: self.sharedFeaturesAvailable)
            }
        }
    }

    func refreshRetrievalHealth(sharedFeaturesAvailable: Bool) {
        self.sharedFeaturesAvailable = sharedFeaturesAvailable
        retrievalHealthTask?.cancel()
        retrievalHealthRequestID += 1
        let requestID = retrievalHealthRequestID
        let retrievalHealthService = retrievalHealthService
        let indexingEnabled = settingsManager.conversationIndexingEnabled
        retrievalHealthTask = Task { [weak self, retrievalHealthService] in
            let snapshot = await retrievalHealthService.snapshot(
                indexingEnabled: indexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.retrievalHealthRequestID == requestID else { return }
                self.retrievalHealthSnapshot = snapshot
                self.retrievalHealthTask = nil
            }
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        selectedContext = result.conversation
        searchQuery = ""
        searchResults = []
        inputText = "Tell me more about my work on \(result.conversation.inferredTaskTitle)"
    }

    func handleSearchQueryChange(previousValue: String) {
        let previousTrimmed = previousValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrimmed = normalizedSearchQuery()
        guard previousTrimmed != currentTrimmed else { return }

        // Any material query change invalidates the in-flight request so late completions cannot
        // overwrite the current UI state.
        searchQueryRevision += 1
        cancelCurrentSearch(clearResults: true)
        if currentTrimmed.isEmpty {
            refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        } else {
            isSearching = true
        }
    }

    func cancelCurrentSearch(clearResults: Bool) {
        searchTask?.cancel()
        searchTask = nil
        activeSearchQuery = nil
        isSearching = false
        if clearResults {
            searchResults = []
        }
    }

    func nextSearchRequestID() -> Int {
        activeSearchRequestID += 1
        return activeSearchRequestID
    }

    func normalizedSearchQuery() -> String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
