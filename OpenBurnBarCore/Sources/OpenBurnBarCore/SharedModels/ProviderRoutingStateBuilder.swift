import Foundation

/// Single source of truth for the human-readable label and SF Symbol glyph
/// that describes a routing candidate's quota state. Used by the routing
/// cockpit, account chips, and accessibility summaries on every platform so
/// the same lane reads the same way across Settings, Dashboard, Popover,
/// and iPhone/iPad. Color tints stay platform-specific because they bind to
/// the active design system.
public enum ProviderRoutingStateText {
    public static func label(_ state: ProviderRoutingQuotaState) -> String {
        switch state {
        case .healthy: return "Healthy"
        case .pressure: return "High usage"
        case .unknown: return "Quota unknown"
        case .exhausted: return "Exhausted"
        case .rateLimited: return "Rate limited"
        case .authFailed: return "Auth failed"
        case .coolingDown: return "Cooling down"
        case .disabled: return "Disabled"
        case .deleted: return "Removed"
        }
    }

    public static func iconName(_ state: ProviderRoutingQuotaState) -> String {
        switch state {
        case .healthy: return "checkmark.circle.fill"
        case .pressure: return "gauge.with.dots.needle.67percent"
        case .unknown: return "questionmark.circle"
        case .exhausted: return "xmark.octagon.fill"
        case .rateLimited: return "tortoise.fill"
        case .authFailed: return "exclamationmark.shield.fill"
        case .coolingDown: return "snowflake"
        case .disabled: return "pause.circle.fill"
        case .deleted: return "trash.slash.fill"
        }
    }
}

/// Derives a `ProviderRoutingStateSnapshot` from synced provider account
/// documents and the latest per-account quota snapshots.
///
/// This is the single source of truth for the routing-aware cockpit on
/// surfaces that *don't* run the live router (iPhone, iPad, future remote
/// dashboards). The builder feeds the same `ProviderRoutingPolicy.decide`
/// contract that the Mac uses, so the active lane on a phone matches the
/// active lane on the Mac for the same account/snapshot inputs.
public enum ProviderRoutingStateBuilder {

    /// Derive a routing snapshot for one provider.
    ///
    /// - Parameters:
    ///   - providerID: Provider whose routing state should be derived.
    ///   - accounts: Synced provider account documents (already filtered to
    ///     the target provider).
    ///   - snapshots: Per-account quota snapshots (any provider; the builder
    ///     filters by `accountID`).
    ///   - now: Clock used by the routing policy. Tests inject a fixed date.
    ///
    /// - Returns: `nil` when there are no non-deleted accounts. Otherwise a
    ///   `ProviderRoutingStateSnapshot` containing the active lane, next
    ///   fallback, and any blocked accounts.
    public static func build(
        providerID: ProviderID,
        accounts: [ProviderAccountDoc],
        snapshots: [ProviderQuotaSnapshot],
        now: Date = Date()
    ) -> ProviderRoutingStateSnapshot? {
        let activeAccounts = accounts.filter { $0.providerID == providerID && $0.status != .deleted }
        guard !activeAccounts.isEmpty else { return nil }

        // Deterministic priority order: default first, then sortKey ascending,
        // then label as a stable tiebreaker. This mirrors the priority that
        // `ProviderQuotaService` produces on the Mac so the cockpit on
        // iPhone/iPad shows the same active lane as the Mac router.
        let ordered = activeAccounts.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }

        let candidates = ordered.enumerated().map { rank, account in
            candidate(for: account, sortIndex: rank, snapshots: snapshots, now: now)
        }

        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(preferredProviderIDs: [providerID]),
            candidates: candidates,
            now: now
        )

        return ProviderRoutingStateSnapshot(
            activeAccount: decision.selected,
            nextFallback: decision.nextFallback,
            exhaustedOrCoolingDownAccounts: decision.exhaustedOrCoolingDown,
            lastSwitchReason: decision.lastSwitchReason,
            recentEvents: [decision.event]
        )
    }

    /// Public so the routing cockpit's same-process tests can verify the
    /// quota-state mapping directly.
    public static func quotaState(
        for account: ProviderAccountDoc,
        snapshot: ProviderQuotaSnapshot?
    ) -> ProviderRoutingQuotaState {
        switch account.status {
        case .deleted:
            return .deleted
        case .disabled:
            return .disabled
        case .error, .disconnected:
            // Both surfaces look the same to the user: this account can't
            // serve traffic until they sign in or fix credentials.
            return .authFailed
        case .stale, .connected:
            break
        }

        guard let snapshot else {
            // No quota signal yet: stale connections stay pessimistic to
            // avoid pretending we routed there; fresh connections fall back
            // to the explicit `.unknown` bucket so the policy still
            // considers them eligible.
            return account.status == .stale ? .pressure : .unknown
        }

        // Pick the bucket with the smallest remaining fraction so a single
        // exhausted axis (e.g. requests-per-day) still trips the lane even
        // when total tokens look fine.
        let bucketsWithLimit = snapshot.displayableQuotaBuckets
        guard let pressuredBucket = bucketsWithLimit.min(by: {
            (max(0, $0.remaining) / $0.limit) < (max(0, $1.remaining) / $1.limit)
        }) else {
            return snapshot.confidence == .stale ? .pressure : .unknown
        }

        let remaining = max(0, pressuredBucket.remaining) / pressuredBucket.limit
        if remaining <= 0 { return .exhausted }
        if remaining <= 0.20 { return .pressure }
        return snapshot.confidence == .stale ? .pressure : .healthy
    }

    private static func candidate(
        for account: ProviderAccountDoc,
        sortIndex: Int,
        snapshots: [ProviderQuotaSnapshot],
        now: Date
    ) -> ProviderRoutingCandidate {
        // Caller may pass multiple snapshots per account (sync history,
        // retries, in-flight refreshes). Pick the freshest one by
        // `fetchedAt` so the cockpit always reflects the most recent server
        // truth instead of whichever entry happened to be first.
        let snapshot = snapshots
            .filter { $0.accountID == account.id }
            .max(by: { $0.fetchedAt < $1.fetchedAt })
        let state = quotaState(for: account, snapshot: snapshot)

        // The router treats an empty `credentialHandle` as
        // `.missingCredential` and skips the account. Synced surfaces cannot
        // see the real handle (that lives in Keychain on the Mac), so we
        // synthesize a stable, non-secret sentinel derived from the account
        // ID. The candidate initializer sanitizes the value, and no rendered
        // surface ever displays it.
        let handle: String = {
            let trimmed = account.redactedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "synced:\(account.id)" : trimmed
        }()

        // `localCredentialAvailable` is the policy's tiebreaker between
        // otherwise-equal healthy candidates. Synced surfaces (iPhone, iPad)
        // can never *actually* hold the secret — it lives in the originating
        // Mac's Keychain. We forward `true` for keychain/local-only scopes
        // so the cockpit's chosen lane matches the Mac router's decision for
        // the same inputs; mobile is intentionally a mirror, not an
        // independent router.
        let localCredentialAvailable = account.storageScope == .deviceKeychain
            || account.storageScope == .localOnly

        return ProviderRoutingCandidate(
            providerID: account.providerID,
            accountID: account.id,
            accountLabel: account.label,
            credentialHandle: handle,
            storageScope: account.storageScope,
            modelCompatibility: .unknown,
            quotaState: state,
            cooldownUntil: nil,
            // Lower wins; default account has already been moved to index 0
            // by the caller, so we just forward the deterministic rank.
            priority: sortIndex,
            routingEnabled: account.status != .disabled && account.status != .deleted,
            lastUsedAt: account.lastRefreshAt,
            lastFailureCode: account.lastErrorCode,
            localCredentialAvailable: localCredentialAvailable
        )
    }
}
