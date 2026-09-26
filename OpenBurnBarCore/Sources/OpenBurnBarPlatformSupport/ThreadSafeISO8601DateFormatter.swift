import Foundation
#if canImport(os)
import os
#endif

// MARK: - Thread-Safe Date Formatter

/// A thread-safe wrapper around ISO8601DateFormatter instances.
///
/// `ISO8601DateFormatter` is documented as not being thread-safe. This actor
/// provides safe concurrent access to formatter instances by serializing
/// access through actor isolation.
///
/// Usage:
/// ```swift
/// let date = await ThreadSafeISO8601DateFormatter.shared.parseFractionalOrBasic(string)
/// ```
public actor ThreadSafeISO8601DateFormatter {

    // MARK: - Singleton Access

    /// Shared singleton instance for convenience.
    public static let shared = ThreadSafeISO8601DateFormatter()

    // MARK: - Formatter Instances

    /// ISO8601 formatter with fractional seconds support.
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ISO8601 formatter without fractional seconds.
    private let basicFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Initialization

    public init() {}

    // MARK: - Parsing

    /// Parses an ISO8601 string, trying fractional seconds first, then basic format.
    /// - Parameter string: The ISO8601-formatted date string.
    /// - Returns: A `Date` if parsing succeeds, `nil` otherwise.
    public func parseFractionalOrBasic(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) {
            return date
        }
        return basicFormatter.date(from: string)
    }

    /// Parses an ISO8601 string with fractional seconds.
    /// - Parameter string: The ISO8601-formatted date string with fractional seconds.
    /// - Returns: A `Date` if parsing succeeds, `nil` otherwise.
    public func parseFractional(_ string: String) -> Date? {
        fractionalFormatter.date(from: string)
    }

    /// Parses an ISO8601 string without fractional seconds.
    /// - Parameter string: The ISO8601-formatted date string without fractional seconds.
    /// - Returns: A `Date` if parsing succeeds, `nil` otherwise.
    public func parseBasic(_ string: String) -> Date? {
        basicFormatter.date(from: string)
    }

    // MARK: - Formatting

    /// Formats a date as an ISO8601 string with fractional seconds.
    /// - Parameter date: The date to format.
    /// - Returns: An ISO8601-formatted string with fractional seconds.
    public func formatFractional(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    /// Formats a date as an ISO8601 string without fractional seconds.
    /// - Parameter date: The date to format.
    /// - Returns: An ISO8601-formatted string without fractional seconds.
    public func formatBasic(_ date: Date) -> String {
        basicFormatter.string(from: date)
    }
}

// MARK: - Synchronous Convenience Methods

/// Extension providing non-isolated, synchronous access to thread-safe date parsing.
///
/// These methods share lock-guarded cached formatters. Allocating and configuring
/// an `ISO8601DateFormatter` per call costs ~4-5x more than a guarded parse, and
/// the log-ingestion hot paths call these once per timestamp across the whole
/// session corpus.
extension ThreadSafeISO8601DateFormatter {

    /// Lock-guarded formatter pair backing the synchronous static helpers.
    /// Both formatters are configured once at init and never mutated afterwards;
    /// every parse still happens under the lock because `ISO8601DateFormatter`
    /// is not documented as thread-safe.
    ///
    /// ISO8601DateFormatter is not thread-safe; all access runs under a lock.
    /// sendable-allowlist: locked-formatter-cache
    private final class SyncFormatterCache: @unchecked Sendable {
        // `ISO8601DateFormatter` is not Sendable and is not documented as
        // thread-safe for concurrent parsing, so every parse runs under a lock.
        // On Apple platforms that lock is an `OSAllocatedUnfairLock`; off-Apple
        // (Windows/Linux Engine subset) `OSAllocatedUnfairLock` is unavailable, so
        // we guard the same formatter pair with an `NSLock`. Access is lock-guarded
        // on both, which is why the class is `@unchecked Sendable`.
        #if canImport(Darwin)
        private let formatters: OSAllocatedUnfairLock<(fractional: ISO8601DateFormatter, basic: ISO8601DateFormatter)>

        init() {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            formatters = OSAllocatedUnfairLock(uncheckedState: (fractional, basic))
        }

        func parseFractionalOrBasic(_ string: String) -> Date? {
            formatters.withLockUnchecked { $0.fractional.date(from: string) ?? $0.basic.date(from: string) }
        }

        func parseBasic(_ string: String) -> Date? {
            formatters.withLockUnchecked { $0.basic.date(from: string) }
        }

        func formatBasic(_ date: Date) -> String {
            formatters.withLockUnchecked { $0.basic.string(from: date) }
        }

        func formatFractional(_ date: Date) -> String {
            formatters.withLockUnchecked { $0.fractional.string(from: date) }
        }
        #else
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let basic: ISO8601DateFormatter

        init() {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            self.fractional = fractional
            self.basic = basic
        }

        func parseFractionalOrBasic(_ string: String) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return fractional.date(from: string) ?? basic.date(from: string)
        }

        func parseBasic(_ string: String) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return basic.date(from: string)
        }

        func formatBasic(_ date: Date) -> String {
            lock.lock(); defer { lock.unlock() }
            return basic.string(from: date)
        }

        func formatFractional(_ date: Date) -> String {
            lock.lock(); defer { lock.unlock() }
            return fractional.string(from: date)
        }
        #endif
    }

    private static let syncCache = SyncFormatterCache()

    /// Synchronously parses an ISO8601 string, trying fractional first then basic.
    ///
    /// - Parameter string: The ISO8601-formatted date string.
    /// - Returns: A `Date` if parsing succeeds, `nil` otherwise.
    public static func parse(_ string: String) -> Date? {
        syncCache.parseFractionalOrBasic(string)
    }

    /// Synchronously parses an ISO8601 string without fractional seconds.
    /// Matches the acceptance of a default-configured `ISO8601DateFormatter()`
    /// (`[.withInternetDateTime]` only) for parsers that rely on that exact behavior.
    ///
    /// - Parameter string: The ISO8601-formatted date string without fractional seconds.
    /// - Returns: A `Date` if parsing succeeds, `nil` otherwise.
    public static func parseBasic(_ string: String) -> Date? {
        syncCache.parseBasic(string)
    }

    /// Synchronously formats a date as ISO8601 without fractional seconds.
    /// Matches `ISO8601DateFormatter().string(from:)` with default options.
    public static func formatBasic(_ date: Date) -> String {
        syncCache.formatBasic(date)
    }

    /// Synchronously formats a date as ISO8601 with fractional seconds.
    public static func formatFractional(_ date: Date) -> String {
        syncCache.formatFractional(date)
    }
}
