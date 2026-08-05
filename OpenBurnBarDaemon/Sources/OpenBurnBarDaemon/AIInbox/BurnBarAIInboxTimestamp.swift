import Foundation
import OpenBurnBarEngine

/// ISO-8601 timestamp codec for AI Inbox rows.
///
/// The inbox writes timestamps on every row and formats them from a synchronous
/// SQLite queue, so the actor-isolated `ThreadSafeISO8601DateFormatter` is not
/// usable here and allocating a formatter per call (the `pcm_*` precedent) is
/// wasteful at tick volume. Instead a single formatter pair is protected by its
/// own lock — the standard trade for a type Foundation documents as
/// non-thread-safe.
///
/// Rows are written WITH fractional seconds and parsed leniently, so timestamps
/// produced by a GRDB migration, by Python, or by hand all decode.
enum BurnBarAIInboxTimestamp {
    // AUDIT(nonisolated(unsafe)): both formatters are only ever touched while
    // `lock` is held; see `string(from:)` / `date(from:)` below.
    // sendable-allowlist: foundation-sdk-shim
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // sendable-allowlist: foundation-sdk-shim
    nonisolated(unsafe) private static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // sendable-allowlist: foundation-sdk-shim
    /// GRDB's on-disk `Date` format: `yyyy-MM-dd HH:mm:ss.SSS`, UTC, POSIX.
    ///
    /// This is NOT interchangeable with the ISO form above, and the difference is
    /// silent and total. The app writes `conversations` and `token_usage`
    /// timestamps by binding `Date` values, which GRDB serializes with this
    /// formatter (`Vendor/GRDB-SQLCipher/.../Date.swift`). SQLite then compares
    /// those columns as plain TEXT.
    ///
    /// The two formats diverge at byte 11 — `' '` (0x20) versus `'T'` (0x54) —
    /// and `'T'` sorts after every digit. So an ISO bound is lexicographically
    /// greater than every same-day GRDB timestamp, and `WHERE startTime >= ?`
    /// silently matches **nothing**. No error, no warning: just an empty result
    /// set forever.
    ///
    /// Rule: bind `grdbString` when comparing against an APP-owned table
    /// (`conversations`, `token_usage`); bind `string` for the daemon-owned
    /// `ai_inbox_*` tables, which the daemon both writes and reads.
    ///
    /// Mirrors `BurnBarChatThreadService.grdbStorageTimestamp`, which solved this
    /// same problem for `chat_messages`.
    nonisolated(unsafe) private static let grdbStorage: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let lock = NSLock()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    /// Timestamp for comparing against an app-owned GRDB `Date` column.
    /// See the note on `grdbStorage` for why this must not be the ISO form.
    static func grdbString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return grdbStorage.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string, string.isEmpty == false else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let date = fractional.date(from: string) { return date }
        if let date = basic.date(from: string) { return date }
        // Legacy SQLite `datetime()` output ("YYYY-MM-DD HH:MM:SS") appears in
        // older `token_usage` / `conversations` rows written before the ISO
        // convention settled. Normalizing here keeps every detector that reads
        // those tables from having to special-case it.
        let normalized = string.replacingOccurrences(of: " ", with: "T")
        if normalized.hasSuffix("Z") == false, normalized.contains("+") == false {
            return basic.date(from: normalized + "Z") ?? fractional.date(from: normalized + "Z")
        }
        return basic.date(from: normalized)
    }
}
