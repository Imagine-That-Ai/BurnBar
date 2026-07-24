import Foundation
import OpenBurnBarKernel

/// Fail-closed validation for adapter output before it crosses a daemon/UI
/// boundary. This validates provenance and numeric safety without requiring a
/// provider credential or making a network request.
public enum ProviderQuotaSnapshotValidationFailure: String, Codable, Error, Hashable, Sendable {
    case missingProviderIdentity
    case providerIdentityMismatch
    case unavailableSnapshotHasBuckets
    case unavailableSnapshotHasFreshConfidence
    case futureFetchedAt
    case futureUpdatedAt
    case nonFiniteBucketValue
}

public enum ProviderQuotaSnapshotValidator {
    /// Small clock skew is normal across a provider response and the local
    /// process. Larger future timestamps are not safe to display as fresh.
    public static let allowedFutureClockSkew: TimeInterval = 5 * 60

    /// Returns `nil` for an accepted snapshot, otherwise a precise reason for
    /// rejecting the response. `expectedProvider` is optional so catalog-only
    /// providers (such as test or custom routes) can still be validated.
    public static func validate(
        _ snapshot: ProviderQuotaSnapshot,
        expectedProvider: ProviderID? = nil,
        now: Date = Date()
    ) -> ProviderQuotaSnapshotValidationFailure? {
        let provider = snapshot.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !snapshot.providerID.rawValue.isEmpty else {
            return .missingProviderIdentity
        }
        guard ProviderID(rawValue: provider) == snapshot.providerID,
              expectedProvider.map({ $0 == snapshot.providerID }) ?? true else {
            return .providerIdentityMismatch
        }

        if snapshot.fetchedAt.timeIntervalSince(now) > allowedFutureClockSkew {
            return .futureFetchedAt
        }
        if snapshot.updatedAt.timeIntervalSince(now) > allowedFutureClockSkew {
            return .futureUpdatedAt
        }

        if snapshot.sourceKind == .unavailable {
            guard snapshot.buckets.isEmpty else { return .unavailableSnapshotHasBuckets }
            guard snapshot.confidence == .stale else { return .unavailableSnapshotHasFreshConfidence }
        }

        for bucket in snapshot.buckets {
            guard bucket.used.isFinite,
                  bucket.limit.isFinite,
                  bucket.remaining.isFinite,
                  bucket.usedValue.map({ $0.isFinite }) ?? true,
                  bucket.limitValue.map({ $0.isFinite }) ?? true,
                  bucket.remainingValue.map({ $0.isFinite }) ?? true,
                  bucket.usedPercent.map({ $0.isFinite }) ?? true else {
                return .nonFiniteBucketValue
            }
        }
        return nil
    }

    public static func accepted(
        _ snapshot: ProviderQuotaSnapshot,
        expectedProvider: ProviderID? = nil,
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        guard validate(snapshot, expectedProvider: expectedProvider, now: now) == nil else {
            return nil
        }
        return snapshot
    }
}
