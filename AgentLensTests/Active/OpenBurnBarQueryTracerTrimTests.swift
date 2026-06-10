import GRDB
import XCTest
@testable import OpenBurnBar

/// The DEBUG query tracer now stays installed for the whole app session
/// (`DataStoreCoordinator` configures it on every pool it opens), so the
/// retained log must be bounded: crossing 5 000 entries drops the oldest half
/// while keeping the newest statements available for `assertMaxQueries` /
/// N+1 analysis.
final class OpenBurnBarQueryTracerTrimTests: XCTestCase {
    override func tearDown() {
        OpenBurnBarQueryTracer.shared.resetLog()
        super.tearDown()
    }

    func test_recordedLogIsBoundedAndKeepsTheNewestStatements() throws {
        var config = Configuration()
        OpenBurnBarQueryTracer.shared.configure(in: &config)
        let queue = try DatabaseQueue(configuration: config)

        try queue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE trim_probe (id INTEGER PRIMARY KEY, n INTEGER)")
        }
        OpenBurnBarQueryTracer.shared.resetLog()

        // Fill exactly to the cap: no trim yet.
        try queue.inDatabase { db in
            for index in 0..<5_000 {
                try db.execute(sql: "INSERT INTO trim_probe (n) VALUES (\(index))")
            }
        }
        XCTAssertEqual(OpenBurnBarQueryTracer.shared.queryCount, 5_000, "the cap itself is reachable")

        // One past the cap drops the oldest half (keeps 2 500 + the new one).
        try queue.inDatabase { db in
            try db.execute(sql: "INSERT INTO trim_probe (n) VALUES (5000) -- newest-marker")
        }
        XCTAssertEqual(OpenBurnBarQueryTracer.shared.queryCount, 2_501)

        let log = OpenBurnBarQueryTracer.shared.queryLog
        XCTAssertTrue(
            log.last?.sql.contains("newest-marker") == true,
            "trimming must drop the OLDEST entries, never the newest"
        )
        XCTAssertTrue(
            log.first?.sql.contains("VALUES (2500)") == true,
            "after dropping the oldest 2 500, the log starts at statement #2500"
        )
    }

    func test_resetLogClearsRetainedQueries() throws {
        var config = Configuration()
        OpenBurnBarQueryTracer.shared.configure(in: &config)
        let queue = try DatabaseQueue(configuration: config)
        try queue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE reset_probe (id INTEGER PRIMARY KEY)")
        }
        XCTAssertGreaterThan(OpenBurnBarQueryTracer.shared.queryCount, 0)
        OpenBurnBarQueryTracer.shared.resetLog()
        XCTAssertEqual(OpenBurnBarQueryTracer.shared.queryCount, 0)
    }
}
