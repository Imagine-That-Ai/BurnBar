import Foundation

enum PhoneControlSendRateLimiter {
    private static let lock = NSLock()
    // Protected by `lock`; Swift 6's global-state diagnostic cannot infer
    // that synchronization from the NSLock calls below.
    private nonisolated(unsafe) static var stamps: [Int64] = []
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
