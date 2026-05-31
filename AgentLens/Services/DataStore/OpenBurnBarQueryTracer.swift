/**
 * GRDB Query Tracing — N+1 Query Detection for OpenBurnBar
 *
 * Enables SQL query tracing in DEBUG builds to catch N+1 query patterns
 * during development and testing. Logs all SQL statements to the unified
 * os_log and emits warnings when query counts within a single operation
 * exceed a configurable threshold.
 *
 * ## Setup
 *
 * Configure the tracer on a `Configuration` *before* opening the database:
 * ```swift
 * var config = Configuration()
 * OpenBurnBarQueryTracer.shared.configure(in: &config)
 * let dbQueue = try DatabaseQueue(path: path, configuration: config)
 * ```
 *
 * ## Usage in tests
 *
 * ```swift
 * let tracer = OpenBurnBarQueryTracer.shared
 * tracer.resetLog()
 * try dbQueue.read { db in _ = try TokenUsage.fetchAll(db) }
 * tracer.assertMaxQueries(count: 3)
 * ```
 *
 * ## How it works
 *
 * GRDB's `Configuration.prepareDatabase` closure runs once per underlying
 * SQLite connection. Inside that closure, `db.trace(options: .statement)`
 * registers a hook that fires for every SQL statement before execution.
 * The tracer accumulates statements in a thread-safe log for later analysis.
 */

import Foundation
import GRDB
import os.log

// MARK: - Query Tracer

/// N+1 query detector and SQL trace logger for GRDB in debug builds.
///
/// Configure via `configure(in:)` before opening a `DatabaseQueue` or
/// `DatabasePool`. Asserting and analysing captured queries is safe to call
/// from any thread after database access completes.
public final class OpenBurnBarQueryTracer: @unchecked Sendable {

    public static let shared = OpenBurnBarQueryTracer()

    // MARK: - Private state

    private let lock = NSLock()
    private var _isEnabled = false
    private var _queryLog: [TracedQuery] = []
    private var _queryThreshold = 10

    private let log = OSLog(subsystem: "com.openburnbar", category: "GRDB.Tracer")

    private init() {}

    // MARK: - Configuration

    /// Maximum queries to the same table within a traced block before emitting
    /// an N+1 warning. Default: 10 (conservative for existing code).
    public var queryThreshold: Int {
        get { lock.withLock { _queryThreshold } }
        set { lock.withLock { _queryThreshold = newValue } }
    }

    public var isEnabled: Bool {
        lock.withLock { _isEnabled }
    }

    // MARK: - GRDB Configuration

    /// Installs the query tracer into a GRDB `Configuration`.
    /// Call this before creating a `DatabaseQueue` or `DatabasePool`.
    ///
    /// ```swift
    /// var config = Configuration()
    /// OpenBurnBarQueryTracer.shared.configure(in: &config)
    /// let dbQueue = try DatabaseQueue(path: path, configuration: config)
    /// ```
    ///
    /// - Parameter configuration: The GRDB configuration to mutate.
    public func configure(in configuration: inout Configuration) {
        let existingPrepare = configuration.prepareDatabase
        let tracer = self
        configuration.prepareDatabase = { db in
            try existingPrepare?(db)
            tracer.lock.withLock { tracer._isEnabled = true }
            db.trace(options: .statement) { event in
                guard tracer.isEnabled else { return }
                switch event {
                case .statement(let statement):
                    tracer.record(sql: statement.sql)
                default:
                    break
                }
            }
        }
        os_log(.debug, log: log, "GRDB query tracer configured — will attach on next connection open")
    }

    // MARK: - Recording

    private func record(sql: String) {
        let query = TracedQuery(sql: sql.trimmingCharacters(in: .whitespacesAndNewlines))
        lock.withLock { _queryLog.append(query) }
        os_log(.debug, log: log, "[GRDB] %{public}@", query.sql)
    }

    // MARK: - Log access

    /// Resets the query log. Call before the operation under test.
    public func resetLog() {
        lock.withLock { _queryLog = [] }
    }

    /// All queries recorded since the last `resetLog()`.
    public var queryLog: [TracedQuery] {
        lock.withLock { _queryLog }
    }

    /// Total number of queries recorded since the last `resetLog()`.
    public var queryCount: Int {
        lock.withLock { _queryLog.count }
    }

    // MARK: - N+1 Analysis

    /// Returns tables queried more than `queryThreshold` times —
    /// the classic sign of an N+1 problem.
    public func detectNPlusOne() -> [NPlusOneViolation] {
        let queries = lock.withLock { _queryLog }
        var tableCounts: [String: Int] = [:]

        for query in queries {
            if let table = extractTableName(from: query.sql) {
                tableCounts[table, default: 0] += 1
            }
        }

        return tableCounts.compactMap { table, count in
            count > queryThreshold ? NPlusOneViolation(table: table, queryCount: count) : nil
        }.sorted { $0.queryCount > $1.queryCount }
    }

    private func extractTableName(from sql: String) -> String? {
        let uppercased = sql.uppercased()
        guard let fromRange = uppercased.range(of: " FROM ") else { return nil }
        let afterFrom = String(uppercased[fromRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return afterFrom.components(separatedBy: .whitespaces).first.flatMap { raw in
            let cleaned = String(raw.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    // MARK: - Test Assertions

    /// Asserts that the number of queries captured since the last `resetLog()`
    /// does not exceed `count`. Call after the database operation under test.
    ///
    /// ```swift
    /// tracer.resetLog()
    /// try dbQueue.read { db in _ = try TokenUsage.fetchAll(db) }
    /// tracer.assertMaxQueries(count: 3)
    /// ```
    public func assertMaxQueries(
        count maxCount: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let actual = queryCount
        if actual > maxCount {
            let sqls = queryLog.map(\.sql).joined(separator: "\n  ")
            assertionFailure(
                "N+1 detected: expected ≤\(maxCount) queries, got \(actual)\n  \(sqls)",
                file: file,
                line: line
            )
        }
        let violations = detectNPlusOne()
        if !violations.isEmpty {
            os_log(.error, log: log, "N+1 violations: %{public}@",
                   violations.map { "\($0.table): \($0.queryCount)x" }.joined(separator: ", "))
        }
    }

    // MARK: - Types

    public struct TracedQuery: Sendable {
        public let sql: String
        public let timestamp: Date = .now
    }

    public struct NPlusOneViolation: Sendable {
        public let table: String
        public let queryCount: Int
    }
}

// MARK: - Configuration Extension

extension Configuration {
    /// Returns a new `Configuration` with the shared `OpenBurnBarQueryTracer`
    /// installed. Use in DEBUG builds only.
    ///
    /// ```swift
    /// #if DEBUG
    /// let dbQueue = try DatabaseQueue(path: path, configuration: .withQueryTracing())
    /// #else
    /// let dbQueue = try DatabaseQueue(path: path)
    /// #endif
    /// ```
    public static func withQueryTracing(base: Configuration = Configuration()) -> Configuration {
        var config = base
        OpenBurnBarQueryTracer.shared.configure(in: &config)
        return config
    }
}
