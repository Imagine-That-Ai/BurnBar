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
        /// Refreshed records from persistence so the caller can replace usages.
        var refreshedRecords: [TokenUsage]?
        /// Drift events: per-credential entries where local cost diverges from
        /// billing-API cost by more than 5%. Each entry names the credential,
        /// the local total, the API total, and the percent divergence.
        var driftEvents: [BillingDriftEvent] = []
    }

    /// Runs the full billing reconciliation pipeline:
    /// 1. Deletes prior API-reconciled usage rows
    /// 2. Rebuilds API service configuration
    /// 3. Fetches billing data from all configured providers
    /// 4. Computes supplemental usage deltas via `BillingUsageReconciliation`
    /// 5. Persists supplemental rows and reloads the canonical set
    /// 6. Detects drift between local-pricing totals and billing-API totals (>5%)
    ///
    /// Each step that can fail appends to `Result.errors` without aborting
    /// the remaining steps.
    nonisolated static func reconcile(
        dataStoreActor: DataStoreActor,
        usageAPIService: ProviderUsageAPIService?,
        allParsedUsages: [TokenUsage],
        persistAndReload: ([TokenUsage]) async throws -> [TokenUsage],
        deleteAndReload: (String) async throws -> [TokenUsage],
        recordDriftEvent: (BillingDriftEvent) -> Void = { _ in }
    ) async -> Result {
        var result = Result()
        var refreshedRecords: [TokenUsage]?

        // 1. Clear prior API-reconciled rows
        do {
            let records = try await deleteAndReload(
                BillingUsageReconciliation.apiReconciliationSessionPrefix
            )
            refreshedRecords = records
        } catch {
            result.errors.append("Failed to clear prior API-reconciled usage rows: \(error.localizedDescription)")
        }

        guard let apiService = usageAPIService else {
            result.apiUsages = []
            result.refreshedRecords = refreshedRecords
            return result
        }

        // 2. Rebuild API configurations
        await MainActor.run { apiService.rebuildAPIs() }

        let configuredProviders = await MainActor.run { apiService.configuredProviders }
        guard !configuredProviders.isEmpty else {
            result.apiUsages = []
            result.refreshedRecords = refreshedRecords
            return result
        }

        // 3. Fetch billing data
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
        result.apiUsages = await apiService.fetchAll(since: thirtyDaysAgo)

        // 4. Compute canonical baseline
        // VAL-CROSS-011: Use canonical multi-source baseline from database, not just parser output.
        let canonicalBaseline: [TokenUsage]
        do {
            canonicalBaseline = try dataStoreActor.usageStore.fetchAllUsage()
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
                let records = try await persistAndReload(result.supplementalUsages)
                refreshedRecords = records
            } catch {
                result.errors.append("Failed to store API-reconciled usage rows: \(error.localizedDescription)")
            }
        }

        // 7. Drift detection: compare local-pricing spend vs billing-API spend per credential.
        //    Flags any credential where divergence exceeds 5%. These drift events feed
        //    budget_events for the "Reconciliation" section in Settings → Budgets.
        let baselineByCredential: [String: [TokenUsage]] = Dictionary(grouping: canonicalBaseline) { usage in
            "\(usage.providerID.rawValue):\(usage.providerAccountID ?? "default")"
        }
        let apiByCredential: [String: [ProviderUsageRecord]] = Dictionary(grouping: result.apiUsages) { record in
            "\(record.providerName):default"
        }
        var driftEvents: [BillingDriftEvent] = []
        for (key, localUsages) in baselineByCredential {
            let localCost = localUsages.reduce(into: 0.0) { $0 += $1.cost }
            let apiCost = (apiByCredential[key] ?? []).reduce(into: 0.0) { $0 += $1.costUSD }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let providerID = parts.first ?? key
            let accountID = parts.count > 1 ? parts[1] : "default"
            let divergence = localCost > 0 ? abs(localCost - apiCost) / localCost : 0
            if divergence > 0.05 && localCost > 0.01 {
                let event = BillingDriftEvent(
                    providerID: providerID,
                    accountID: accountID,
                    localCost: localCost,
                    apiCost: apiCost,
                    divergencePercent: divergence * 100
                )
                driftEvents.append(event)
                recordDriftEvent(event)
            }
        }
        result.driftEvents = driftEvents

        result.refreshedRecords = refreshedRecords
        return result
    }
}

/// A single drift event detected during billing reconciliation: the local-pricing
/// cost for a credential diverged from the billing-API cost by more than 5%.
struct BillingDriftEvent: Sendable {
    let providerID: String
    let accountID: String
    let localCost: Double
    let apiCost: Double
    let divergencePercent: Double
}
