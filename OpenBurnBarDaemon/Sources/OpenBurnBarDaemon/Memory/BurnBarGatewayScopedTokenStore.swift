import Foundation

/// Short-lived bearer tokens for the loopback gateway, scoped to a set of
/// `memory-*` purposes. The Python memory engine receives one through the
/// policy courier instead of ever seeing the static gateway token or a
/// provider key. Tokens are random 32-byte hex strings, compared in constant
/// time, and expire after `ttl`.
public actor BurnBarGatewayScopedTokenStore {
    private struct Entry {
        let purposes: Set<String>
        let expiresAt: Date
    }

    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 900) {
        self.now = now
        self.ttl = ttl
    }

    public func mint(purposes: Set<String>) -> (token: String, expiresAt: Date) {
        prune(at: now())
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let expiresAt = now().addingTimeInterval(ttl)
        entries[token] = Entry(purposes: purposes, expiresAt: expiresAt)
        return (token, expiresAt)
    }

    public func validate(token: String, purpose: String, now: Date) -> Bool {
        prune(at: now)
        for (candidate, entry) in entries where constantTimeTokensEqual(candidate, token) {
            return entry.expiresAt > now && entry.purposes.contains(purpose)
        }
        return false
    }

    public func liveTokenCount(now: Date) -> Int {
        prune(at: now)
        return entries.count
    }

    private func prune(at date: Date) {
        entries = entries.filter { $0.value.expiresAt > date }
    }
}
