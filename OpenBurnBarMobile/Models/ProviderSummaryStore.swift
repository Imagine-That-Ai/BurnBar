import Foundation
import OpenBurnBarCore

@Observable @MainActor
final class ProviderSummaryStore {
    private let reader: CloudReader
    private(set) var summaries: [ProviderConnectionDoc] = []
    private(set) var isLoading = false
    private(set) var lastError: CloudErrorClassification?
    private(set) var lastReadAt: Date?

    init(reader: CloudReader = LiveCloudReader()) { self.reader = reader }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do { summaries = try await reader.loadProviderSummaries(); lastError = nil; lastReadAt = Date() }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }
    var isEmptyCloud: Bool { summaries.isEmpty && lastError == nil }
}
