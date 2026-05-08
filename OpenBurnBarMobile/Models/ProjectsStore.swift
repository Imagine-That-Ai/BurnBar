import Foundation
import OpenBurnBarCore
import FirebaseFirestore

// MARK: - Projects Store
//
// Aggregates `users/{uid}/usage` rows by project name to power the new
// Projects surface in Streams. Uses the existing FirestoreRepository
// page-fetcher and runs the aggregation through the pure `ProjectSummaryAggregator`.
//
// Cap: at most 500 most-recent rows aggregated locally — projects with longer
// histories will benefit from the existing rollups but we still want
// per-project drill-downs that aren't currently in the rollup schema.

@Observable
@MainActor
final class ProjectsStore {

    private let firestore: FirestoreRepository
    private let pageSize = 100
    private let maxRows = 500

    private(set) var summaries: [ProjectSummary] = []
    private(set) var rawUsages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            var collected: [TokenUsage] = []
            var cursor: DocumentSnapshot? = nil
            while collected.count < maxRows {
                let (page, last) = try await firestore.fetchUsagePage(
                    pageSize: pageSize,
                    after: cursor,
                    provider: nil,
                    model: nil,
                    device: nil,
                    startDate: nil,
                    endDate: nil
                )
                if page.isEmpty { break }
                collected.append(contentsOf: page)
                cursor = last
                if page.count < pageSize { break }
            }
            rawUsages = collected
            summaries = ProjectSummaryAggregator.aggregate(collected)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async { await load() }

    // MARK: - Selectors

    /// Top N projects by cost.
    func topByCost(limit: Int = 5) -> [ProjectSummary] {
        Array(summaries.sorted { $0.totalCost > $1.totalCost }.prefix(limit))
    }

    /// Most recently active projects.
    func mostRecent(limit: Int = 5) -> [ProjectSummary] {
        Array(summaries.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
    }

    /// Sessions belonging to a specific project (most recent first).
    func sessions(for project: ProjectSummary) -> [TokenUsage] {
        rawUsages
            .filter { $0.projectName.lowercased() == project.id }
            .sorted { $0.startTime > $1.startTime }
    }
}
