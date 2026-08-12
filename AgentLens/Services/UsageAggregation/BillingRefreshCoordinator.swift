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
        /// True when this cycle changed `token_usage` content (deleted prior
        /// API-reconciled rows or persisted new supplemental rows). Purely
        /// informational — the aggregator's post-refresh reload is driven by
        /// the `UsageTableWriteMarker`, which these writes bump.
        var usageRowsChanged = false
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
    /// 5. Persists supplemental rows
    /// 6. Detects drift between local-pricing totals and billing-API totals (>5%)
    ///
    /// Each step that can fail appends to `Result.errors` without aborting
    /// the remaining steps.
    ///
    /// **Bounded-window baseline.** Step 4 used to load the ENTIRE
    /// `token_usage` table (`fetchAllUsage`) every refresh tick. The
    /// reconciliation math only ever matches local rows whose
    /// `[startTime, endTime]` intersects one of the per-record day windows
    /// `startOfDay(record.date)...+1d`, so `fetchReconciliationBaseline` is
    /// handed the earliest such window start and may return just the rows
    /// intersecting `[cutoff, ∞)`. Any superset of those rows produces
    /// byte-identical supplemental output (each record's window filter is
    /// re-applied per record); `RefreshTickPerfTests` asserts the
    /// bounded == full equality on realistic fixtures.
    ///
    /// **Aggregated drift baseline.** Step 6 used the same full-table load to
    /// reduce per-credential all-time cost sums. `fetchCredentialCostTotals`
    /// now returns those sums from one SQL `GROUP BY` — same totals, ~#credential
    /// rows moved instead of the whole history.
    nonisolated static func reconcile(
        usageAPIService: ProviderUsageAPIService?,
        allParsedUsages: [TokenUsage],
        fetchReconciliationBaseline: @Sendable (Date) async throws -> [TokenUsage],
        fetchCredentialCostTotals: @Sendable () async throws -> [String: Double],
        persistSupplemental: @Sendable ([TokenUsage]) async throws -> Void,
        deleteReconciled: @Sendable (String) async throws -> Int,
        recordDriftEvent: @Sendable (BillingDriftEvent) -> Void = { _ in }
    ) async -> Result {
        var result = Result()

        // 1. Clear prior API-reconciled rows
        do {
            let deletedCount = try await deleteReconciled(
                BillingUsageReconciliation.apiReconciliationSessionPrefix
            )
            result.usageRowsChanged = deletedCount > 0
        } catch {
            result.errors.append("Failed to clear prior API-reconciled usage rows: \(error.localizedDescription)")
        }

        guard let apiService = usageAPIService else {
            result.apiUsages = []
            return result
        }

        // 2. Rebuild API configurations
        await MainActor.run { apiService.rebuildAPIs() }

        let configuredProviders = await MainActor.run { apiService.configuredProviders }
        guard !configuredProviders.isEmpty else {
            result.apiUsages = []
            return result
        }

        // 3. Fetch billing data
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
        result.apiUsages = await apiService.fetchAll(since: thirtyDaysAgo)

        // 4. Compute canonical baseline, bounded to the earliest window any
        //    fetched record can match.
        // VAL-CROSS-011: Use canonical multi-source baseline from database, not just parser output.
        var canonicalBaseline: [TokenUsage] = []
        if !result.apiUsages.isEmpty {
            let calendar = Calendar.current
            let defaultCutoff = calendar.startOfDay(for: thirtyDaysAgo)
            let earliestWindowStart = result.apiUsages
                .map { calendar.startOfDay(for: $0.date) }
                .min() ?? defaultCutoff
            do {
                canonicalBaseline = try await fetchReconciliationBaseline(
                    min(earliestWindowStart, defaultCutoff)
                )
            } catch {
                canonicalBaseline = allParsedUsages
                result.errors.append("Failed to fetch canonical usage baseline: \(error.localizedDescription)")
            }
        }

        // 5. Compute supplemental deltas
        result.supplementalUsages = BillingUsageReconciliation.supplementalUsages(
            from: result.apiUsages,
            existingUsages: canonicalBaseline
        )

        // 6. Persist supplemental rows
        if !result.supplementalUsages.isEmpty {
            do {
                try await persistSupplemental(result.supplementalUsages)
                result.usageRowsChanged = true
            } catch {
                result.errors.append("Failed to store API-reconciled usage rows: \(error.localizedDescription)")
            }
        }

        // 7. Drift detection: compare local-pricing spend vs billing-API spend per credential.
        //    Flags any credential where divergence exceeds 5%. These drift events feed
        //    budget_events for the "Reconciliation" section in Settings → Budgets.
        let credentialCostTotals: [String: Double]
        do {
            credentialCostTotals = try await fetchCredentialCostTotals()
        } catch {
            // Same degradation as the old full-table path: fall back to the
            // parser output for this cycle.
            credentialCostTotals = Self.credentialCostTotals(from: allParsedUsages)
            result.errors.append("Failed to fetch credential cost totals: \(error.localizedDescription)")
        }
        let apiByCredential: [String: [ProviderUsageRecord]] = Dictionary(grouping: result.apiUsages) { record in
            "\(record.providerName):default"
        }
        var driftEvents: [BillingDriftEvent] = []
        for (key, localCost) in credentialCostTotals {
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

        return result
    }

    /// In-memory equivalent of `UsageStore.driftCredentialCostTotals()` used
    /// as the fallback when the SQL aggregate is unavailable, and by tests to
    /// assert SQL/Swift parity. Key format: `"providerID:accountID-or-default"`.
    static func credentialCostTotals(from usages: [TokenUsage]) -> [String: Double] {
        usages.reduce(into: [String: Double]()) { totals, usage in
            let key = "\(usage.providerID.rawValue):\(usage.providerAccountID ?? "default")"
            totals[key, default: 0] += usage.cost
        }
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
