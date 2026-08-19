import Foundation
import GRDB
import OpenBurnBarKernel

/// Local persistence for War Room standing orders (W6, the rhythm).
///
/// Deliberately thin: every decision about what a row *means* lives in
/// `StandingOrderRow` in the Kernel, which is unit-tested without a database.
/// This type only moves rows.
///
/// One behaviour is load-bearing and lives here: `dueOrders` reads through
/// `StandingOrderScheduler`, so the scheduler is the single answer to "what
/// should run now" whether the caller is the app, the daemon, or a test.
final class StandingOrderStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Read

    func fetchOrders() async throws -> [StandingOrder] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM standing_orders ORDER BY title ASC")
                .compactMap(Self.order(from:))
        }
    }

    func fetchOrder(id: String) async throws -> StandingOrder? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM standing_orders WHERE id = ?", arguments: [id])
                .flatMap(Self.order(from:))
        }
    }

    /// Orders that have come due, longest-overdue first.
    func dueOrders(now: Date = Date(), calendar: Calendar = .current) async throws -> [StandingOrder] {
        let enabled = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM standing_orders WHERE isEnabled = 1")
                .compactMap(Self.order(from:))
        }
        return StandingOrderScheduler.due(orders: enabled, now: now, calendar: calendar)
    }

    // MARK: - Write

    func upsert(_ order: StandingOrder, now: Date = Date()) async throws {
        let row = StandingOrderRow(order: order, updatedAt: now)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO standing_orders
                        (id, title, instruction, cadenceKind, cadenceMinutes, cadenceHour,
                         cadenceMinute, cadenceWeekday, targetBodyId, requiredCapabilities,
                         isEnabled, lastFiredAt, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        instruction = excluded.instruction,
                        cadenceKind = excluded.cadenceKind,
                        cadenceMinutes = excluded.cadenceMinutes,
                        cadenceHour = excluded.cadenceHour,
                        cadenceMinute = excluded.cadenceMinute,
                        cadenceWeekday = excluded.cadenceWeekday,
                        targetBodyId = excluded.targetBodyId,
                        requiredCapabilities = excluded.requiredCapabilities,
                        isEnabled = excluded.isEnabled,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    row.id, row.title, row.instruction, row.cadenceKind, row.cadenceMinutes,
                    row.cadenceHour, row.cadenceMinute, row.cadenceWeekday, row.targetBodyId,
                    row.requiredCapabilities, row.isEnabled, row.lastFiredAt, row.createdAt, row.updatedAt
                ]
            )
        }
    }

    /// Stamp a fire. Kept separate from `upsert` because the upsert path must
    /// never move `lastFiredAt` — editing an order's title would otherwise
    /// reschedule it.
    func markFired(id: String, at date: Date = Date()) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE standing_orders SET lastFiredAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [date, date, id]
            )
        }
    }

    /// Roll a failed dispatch's claim back so the next tick retries the
    /// occurrence. Guarded on the claimed stamp so it never clobbers a newer
    /// fire recorded by anyone else in the window.
    func rollBackFire(id: String, from claimed: Date, to previous: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE standing_orders SET lastFiredAt = ?, updatedAt = ? WHERE id = ? AND lastFiredAt = ?",
                arguments: [previous, claimed, id, claimed]
            )
        }
    }

    func setEnabled(id: String, isEnabled: Bool, now: Date = Date()) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE standing_orders SET isEnabled = ?, updatedAt = ? WHERE id = ?",
                arguments: [isEnabled, now, id]
            )
        }
    }

    func delete(id: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM standing_orders WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Mapping

    /// Reads through GRDB's typed subscript rather than casting the untyped
    /// value: SQLite hands an INTEGER column back as `Int64`, so `as? Int`
    /// silently yields nil and would drop every interval order on the floor.
    private static func order(from row: Row) -> StandingOrder? {
        guard
            let id: String = row["id"],
            let title: String = row["title"],
            let instruction: String = row["instruction"],
            let cadenceKind: String = row["cadenceKind"],
            let createdAt: Date = row["createdAt"],
            let updatedAt: Date = row["updatedAt"]
        else { return nil }

        let isEnabled: Bool = row["isEnabled"] ?? true

        return StandingOrderRow(
            id: id,
            title: title,
            instruction: instruction,
            cadenceKind: cadenceKind,
            cadenceMinutes: row["cadenceMinutes"],
            cadenceHour: row["cadenceHour"],
            cadenceMinute: row["cadenceMinute"],
            cadenceWeekday: row["cadenceWeekday"],
            targetBodyId: row["targetBodyId"],
            requiredCapabilities: row["requiredCapabilities"] ?? "",
            isEnabled: isEnabled,
            lastFiredAt: row["lastFiredAt"],
            createdAt: createdAt,
            updatedAt: updatedAt
        ).order
    }
}
