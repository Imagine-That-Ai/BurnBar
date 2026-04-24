import Foundation

/// Encapsulates the billing API fetch-reconcile-persist cycle that runs
/// at the tail of `UsageAggregator.refreshAll()`.
///
/// The coordinator is intentionally stateless -- it takes all inputs as
/// parameters and returns structured output so the aggregator can apply
/// side effects (setting `parserImportError`, `apiUsages`, etc.).
enum BillingRefreshCoordinator {

    struct Result {
        /// Records fetched from the provider billing APIs.
        var apiUsages: [ProviderUsageRecord] = []
        /// Supplemental `TokenUsage` rows computed by reconciliation.
        var supplementalUsages: [TokenUsage] = []
        /// Non-fatal error messages accumulated during the flow.
        var errors: [String] = []
    }

    /// Runs the full billing reconciliation pipeline:
    /// 1. Deletes prior API-reconciled usage rows
    /// 2. Rebuilds API service configuration
    /// 3. Fetches billing data from all configured providers
    /// 4. Computes supplemental usage deltas via `BillingUsageReconciliation`
    /// 5. Persists supplemental rows and reloads the canonical set
    ///
    /// Each step that can fail appends to `Result.errors` without aborting
    /// the remaining steps.
    @MainActor
    static func reconcile(
        dataStore: DataStore,
        usageAPIService: ProviderUsageAPIService?,
        allParsedUsages: [TokenUsage],
        persistAndReload: ([TokenUsage]) async throws -> [TokenUsage],
        deleteAndReload: (String) async throws -> [TokenUsage]
    ) async -> Result {
        var result = Result()

        // 1. Clear prior API-reconciled rows
        do {
            let refreshedRecords = try await deleteAndReload(
                BillingUsageReconciliation.apiReconciliationSessionPrefix
            )
            dataStore.replaceUsages(refreshedRecords)
        } catch {
            result.errors.append("Failed to clear prior API-reconciled usage rows: \(error.localizedDescription)")
        }

        guard let apiService = usageAPIService else {
            result.apiUsages = []
            return result
        }

        // 2. Rebuild API configurations
        apiService.rebuildAPIs()

        guard !apiService.configuredProviders.isEmpty else {
            result.apiUsages = []
            return result
        }

        // 3. Fetch billing data
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
        result.apiUsages = await apiService.fetchAll(since: thirtyDaysAgo)

        // 4. Compute canonical baseline
        // VAL-CROSS-011: Use canonical multi-source baseline from database, not just parser output.
        let canonicalBaseline: [TokenUsage]
        do {
            canonicalBaseline = try dataStore.usageStore.fetchAllUsage()
        } catch {
            canonicalBaseline = allParsedUsages
            result.errors.append("Failed to fetch canonical usage baseline: \(error.localizedDescription)")
        }

        // 5. Compute supplemental deltas
        result.supplementalUsages = BillingUsageReconciliation.supplementalUsages(
            from: result.apiUsages,
            existingUsages: canonicalBaseline
        )

        // 6. Persist supplemental rows
        if !result.supplementalUsages.isEmpty {
            do {
                let refreshedRecords = try await persistAndReload(result.supplementalUsages)
                dataStore.replaceUsages(refreshedRecords)
            } catch {
                result.errors.append("Failed to store API-reconciled usage rows: \(error.localizedDescription)")
            }
        }

        return result
    }
}
