import Foundation
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Local switcher active-profile writer (test double)
//
// Wave 2.1c-v: production active-profile writes go through the daemon
// (single writer, ADR-005). Tests that need a working switcher store
// without a live daemon inject this double, which performs the exact
// pre-cutover local semantics — the same statements, in the same order —
// against the test queue. Test files are exempt from the dual-writer
// grep, so the legacy SQL lives here and only here.
//
// The daemon assigns `updatedAt` (`Date()` bound through GRDB); the double
// does the same, so timestamps match production byte for byte.

final class LocalSwitcherActiveProfileWriter: SwitcherActiveProfileWriter {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func apply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse {
        try dbQueue.write { db in
            var rowsCleared = 0
            if let clearID = request.clearProfileID {
                try db.execute(
                    sql: """
                    UPDATE switcher_active_profile
                    SET activeProfileID = NULL, updatedAt = ?
                    WHERE activeProfileID = ?
                    """,
                    arguments: [Date(), clearID]
                )
                rowsCleared = db.changesCount
            }
            for set in request.sets {
                try Self.writePointer(
                    db,
                    profileID: set.profileID,
                    providerID: set.providerID
                )
            }
            return BurnBarSwitcherActiveProfileApplyResponse(
                setsApplied: request.sets.count,
                rowsCleared: rowsCleared
            )
        }
    }

    private static func writePointer(
        _ db: Database,
        profileID: String?,
        providerID: String?
    ) throws {
        let now = Date()
        if let providerID {
            try db.execute(
                sql: "DELETE FROM switcher_active_profile WHERE providerID = ?",
                arguments: [providerID]
            )
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, ?, ?)",
                arguments: [profileID, providerID, now]
            )
        } else {
            try db.execute(sql: "DELETE FROM switcher_active_profile WHERE providerID IS NULL")
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, NULL, ?)",
                arguments: [profileID, now]
            )
        }
    }
}

/// Stands in for a daemon that is unreachable: every write throws, proving the
/// store fails closed (no local write, no silent success).
struct ThrowingSwitcherActiveProfileWriter: SwitcherActiveProfileWriter {
    struct Boom: Error {}

    func apply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse {
        throw Boom()
    }
}

/// Records the RPC requests the store issues, so cutover tests can assert the
/// exact app→daemon mapping without a live socket.
final class RecordingSwitcherActiveProfileWriter: SwitcherActiveProfileWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _applies: [BurnBarSwitcherActiveProfileApplyRequest] = []

    var applies: [BurnBarSwitcherActiveProfileApplyRequest] {
        lock.withLock { _applies }
    }

    func apply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse {
        lock.withLock { _applies.append(request) }
        return BurnBarSwitcherActiveProfileApplyResponse(
            setsApplied: request.sets.count,
            rowsCleared: request.clearProfileID == nil ? 0 : 1
        )
    }
}
