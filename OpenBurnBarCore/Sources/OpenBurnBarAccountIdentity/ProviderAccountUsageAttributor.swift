import Foundation
import OpenBurnBarKernel

/// Attributes locally parsed usage rows to the provider account that produced
/// them, so multi-seat setups (three Cursor seats, three OpenAI accounts) can
/// see which account is burning tokens.
///
/// `refreshObservations()` snapshots each tool's currently signed-in identity
/// into the device-local identity timeline; `attribute(_:)` then fills the
/// existing `providerAccountID`/`providerAccountLabel`/`providerAccountSource`
/// fields on rows whose session interval maps to exactly one identity. Rows a
/// parser has already attributed, and rows whose interval spans an account
/// switch, are left untouched.
public final class ProviderAccountUsageAttributor: Sendable {
    private let resolvers: [any ProviderAccountIdentityResolving]
    private let timeline: ProviderAccountIdentityTimelineStore
    private let now: @Sendable () -> Date
    private let observationInterval: TimeInterval

    private let lastObservationAt = Locked<Date?>(nil)

    public init(
        resolvers: [any ProviderAccountIdentityResolving],
        timeline: ProviderAccountIdentityTimelineStore,
        observationInterval: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolvers = resolvers
        self.timeline = timeline
        self.observationInterval = observationInterval
        self.now = now
    }

    public static func live(timelineFileURL: URL) -> ProviderAccountUsageAttributor {
        ProviderAccountUsageAttributor(
            resolvers: .defaultResolvers(),
            timeline: ProviderAccountIdentityTimelineStore(fileURL: timelineFileURL)
        )
    }

    /// Runs every resolver and journals the identities it finds. Throttled to
    /// `observationInterval` because some identity sources (Claude's
    /// `.claude.json`) can be large files.
    public func refreshObservations() {
        let stamp = now()
        let shouldObserve = lastObservationAt.withLock { last -> Bool in
            if let last, stamp.timeIntervalSince(last) < observationInterval { return false }
            last = stamp
            return true
        }
        guard shouldObserve else { return }

        for resolver in resolvers {
            guard let identity = resolver.resolveCurrentIdentity() else { continue }
            for provider in resolver.providers {
                timeline.observe(identity, provider: provider, at: stamp)
            }
        }
    }

    public func attribute(_ usages: [TokenUsage]) -> [TokenUsage] {
        usages.map { usage in
            guard usage.providerAccountID == nil,
                  let window = timeline.attribution(
                      for: usage.provider,
                      start: usage.startTime,
                      end: usage.endTime
                  )
            else { return usage }
            return usage.attributingAccount(
                rawIdentity: window.rawIdentity,
                label: window.label,
                source: window.scope
            )
        }
    }
}
