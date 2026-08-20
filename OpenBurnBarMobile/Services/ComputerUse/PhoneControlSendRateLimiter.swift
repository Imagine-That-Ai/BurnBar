import Foundation

enum PhoneControlSendRateLimiter {
    private static let lock = NSLock()
    // reason: every access is inside `lock`, which is the mutual exclusion Swift 6
    // cannot see through. The alternative is an actor, which would make `consume`
    // async and force `await` into the phone-control send path this limiter exists
    // to keep synchronous.
    nonisolated(unsafe) private static var stamps: [Int64] = []
    private static let windowMs: Int64 = 1_000
    private static let maxEvents = 30

    static func consume(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stamps = stamps.filter { nowMs - $0 < windowMs }
        if stamps.count >= maxEvents { return false }
        stamps.append(nowMs)
        return true
    }
}
