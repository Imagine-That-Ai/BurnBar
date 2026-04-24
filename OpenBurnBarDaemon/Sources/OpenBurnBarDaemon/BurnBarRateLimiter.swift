import Foundation

public struct BurnBarRateLimitConfiguration: Codable, Hashable, Sendable {
    public let requestsPerSecond: Double
    public let burstCapacity: Int

    public init(requestsPerSecond: Double, burstCapacity: Int) {
        self.requestsPerSecond = max(requestsPerSecond, 0.1)
        self.burstCapacity = max(burstCapacity, 1)
    }
}

public enum BurnBarRateLimitResult: Sendable, Equatable {
    case allowed
    case throttled(retryAfter: Double)
}

public actor BurnBarRateLimiter {
    private struct TokenBucket: Sendable {
        var tokens: Double
        var lastUpdated: ContinuousClock.Instant
    }

    private let config: BurnBarRateLimitConfiguration
    private var buckets: [String: TokenBucket] = [:]
    private var lastPruned: ContinuousClock.Instant?
    private let pruneInterval: Duration = .seconds(300) // 5 minutes
    private let bucketIdleTimeout: Duration = .seconds(300) // 5 minutes

    public init(configuration: BurnBarRateLimitConfiguration) {
        self.config = configuration
    }

    public func checkLimit(clientKey: String) -> BurnBarRateLimitResult {
        let now = ContinuousClock.now

        pruneIfNeeded(now: now)

        var bucket = buckets[clientKey] ?? TokenBucket(
            tokens: Double(config.burstCapacity),
            lastUpdated: now
        )

        let elapsed = bucket.lastUpdated.duration(to: now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let tokensToAdd = elapsedSeconds * config.requestsPerSecond

        bucket.tokens = min(Double(config.burstCapacity), bucket.tokens + tokensToAdd)
        bucket.lastUpdated = now

        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0
            buckets[clientKey] = bucket
            return .allowed
        } else {
            buckets[clientKey] = bucket
            let retryAfter = (1.0 - bucket.tokens) / config.requestsPerSecond
            return .throttled(retryAfter: max(retryAfter, 0.1))
        }
    }

    private func pruneIfNeeded(now: ContinuousClock.Instant) {
        if let lastPruned, now.duration(to: lastPruned) < pruneInterval {
            return
        }

        var pruned = 0
        for (key, bucket) in buckets {
            if now.duration(to: bucket.lastUpdated) > bucketIdleTimeout {
                buckets.removeValue(forKey: key)
                pruned += 1
            }
        }
        lastPruned = now

        if pruned > 0 {
            // Silent prune; no logger available in this actor to avoid coupling
        }
    }
}
