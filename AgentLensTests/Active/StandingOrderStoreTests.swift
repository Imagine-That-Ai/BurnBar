import XCTest
import GRDB
@testable import OpenBurnBar
import OpenBurnBarKernel

/// The store is the standing-order runtime's durability. These pin the
/// claim-first dispatch contract: `markFired` is the durable claim the runtime
/// commits before the external mission write, and `rollBackFire` hands the
/// occurrence back after a failed dispatch — without ever clobbering a newer
/// stamp written in the window.
@MainActor
final class StandingOrderStoreTests: XCTestCase {

    private func makeStore() throws -> (StandingOrderStore, DatabaseQueue) {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        return (StandingOrderStore(dbQueue: queue), queue)
    }

    private func makeOrder(lastFiredAt: Date? = nil) -> StandingOrder {
        StandingOrder(
            id: "so-nightly",
            title: "Nightly suite",
            instruction: "run the suite",
            cadence: .everyMinutes(60),
            lastFiredAt: lastFiredAt
        )
    }

    /// SQLite hands INTEGER columns back as `Int64`, so an untyped `as? Int`
    /// read decodes to nil and takes the whole order with it. Pins every
    /// numeric column through a real write-and-read.
    func test_roundTripsEveryColumn() async throws {
        let (store, _) = try makeStore()
        let order = StandingOrder(
            id: "so-weekly",
            title: "Weekly report",
            instruction: "summarise the week",
            cadence: .weekly(weekday: 2, hour: 9, minute: 30),
            targetBodyID: "body-studio",
            requiredCapabilities: ["codex", "shell"],
            isEnabled: false
        )

        try await store.upsert(order)

        let reloaded = try await store.fetchOrder(id: "so-weekly")
        XCTAssertEqual(reloaded?.cadence, .weekly(weekday: 2, hour: 9, minute: 30))
        XCTAssertEqual(reloaded?.targetBodyID, "body-studio")
        XCTAssertEqual(reloaded?.requiredCapabilities, ["codex", "shell"])
        XCTAssertEqual(reloaded?.isEnabled, false, "a disabled order must not reload as enabled")
    }

    func test_markFiredStampsTheClaim() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(makeOrder())
        let claimed = Date(timeIntervalSince1970: 1_755_000_000)

        try await store.markFired(id: "so-nightly", at: claimed)

        let reloaded = try await store.fetchOrder(id: "so-nightly")
        XCTAssertEqual(reloaded?.lastFiredAt, claimed)
    }

    /// A failed dispatch returns the occurrence to the schedule: the next tick
    /// sees the order as still due instead of silently skipping the cycle.
    func test_rollBackFireRestoresThePreviousStamp() async throws {
        let (store, _) = try makeStore()
        let previous = Date(timeIntervalSince1970: 1_754_000_000)
        try await store.upsert(makeOrder(lastFiredAt: previous))
        let claimed = Date(timeIntervalSince1970: 1_755_000_000)
        try await store.markFired(id: "so-nightly", at: claimed)

        try await store.rollBackFire(id: "so-nightly", from: claimed, to: previous)

        let reloaded = try await store.fetchOrder(id: "so-nightly")
        XCTAssertEqual(reloaded?.lastFiredAt, previous)
    }

    /// An order that had never fired rolls back to never-fired, not to some
    /// synthetic epoch.
    func test_rollBackFireRestoresNilForAFirstFire() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(makeOrder())
        let claimed = Date(timeIntervalSince1970: 1_755_000_000)
        try await store.markFired(id: "so-nightly", at: claimed)

        try await store.rollBackFire(id: "so-nightly", from: claimed, to: nil)

        let reloaded = try await store.fetchOrder(id: "so-nightly")
        // Asserted before the stamp, so a row that failed to decode at all
        // cannot satisfy the nil check by disappearing.
        XCTAssertNotNil(reloaded, "the order must still load after a rollback")
        XCTAssertNil(reloaded?.lastFiredAt)
    }

    /// The rollback is guarded on the claimed stamp: if anything moved
    /// `lastFiredAt` after the claim, the rollback must not clobber it.
    func test_rollBackFireRefusesWhenTheStampMoved() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(makeOrder())
        let claimed = Date(timeIntervalSince1970: 1_755_000_000)
        let newer = Date(timeIntervalSince1970: 1_756_000_000)
        try await store.markFired(id: "so-nightly", at: claimed)
        try await store.markFired(id: "so-nightly", at: newer)

        try await store.rollBackFire(id: "so-nightly", from: claimed, to: nil)

        let reloaded = try await store.fetchOrder(id: "so-nightly")
        XCTAssertEqual(reloaded?.lastFiredAt, newer, "a newer fire must survive a stale rollback")
    }

    /// Editing an order must never move `lastFiredAt` — the upsert path would
    /// otherwise reschedule it.
    func test_upsertPreservesTheFireStamp() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(makeOrder())
        let claimed = Date(timeIntervalSince1970: 1_755_000_000)
        try await store.markFired(id: "so-nightly", at: claimed)

        var edited = makeOrder()
        edited.title = "Nightly suite, renamed"
        try await store.upsert(edited)

        let reloaded = try await store.fetchOrder(id: "so-nightly")
        XCTAssertEqual(reloaded?.lastFiredAt, claimed)
        XCTAssertEqual(reloaded?.title, "Nightly suite, renamed")
    }
}
