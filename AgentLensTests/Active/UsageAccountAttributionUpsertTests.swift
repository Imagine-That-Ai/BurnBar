import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Pins the transition from unattributed to account-attributed usage rows.
///
/// The `token_usage` unique index includes `COALESCE(providerAccountID, '')`,
/// so an attributed row does not collide with the same session's previously
/// unattributed row. Without an explicit claim step the attributed row would
/// insert *alongside* its predecessor and double every historical session's
/// tokens and cost on the first refresh after attribution ships.
@MainActor
final class UsageAccountAttributionUpsertTests: XCTestCase {
    func testAttributedRowReplacesItsUnattributedPredecessor() async throws {
        let store = try makeInMemoryDataStore()
        let unattributed = makeUsage()
        try await store.insert(unattributed)

        let attributed = unattributed.attributingAccount(
            rawIdentity: "seat-one@example.com",
            label: "seat-one@example.com",
            source: .localOnly
        )
        try await store.insert(attributed)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 1, "The attributed row must replace, not duplicate, its predecessor.")
        XCTAssertEqual(rows.first?.totalTokens, unattributed.totalTokens)
        XCTAssertEqual(rows.first?.cost, unattributed.cost)
        XCTAssertEqual(rows.first?.providerAccountLabel, "seat-one@example.com")
    }

    func testDistinctAccountsOnDistinctSessionsBothSurvive() async throws {
        let store = try makeInMemoryDataStore()
        let seatOne = makeUsage(sessionId: "session-1").attributingAccount(
            rawIdentity: "seat-one@example.com", label: "seat-one@example.com", source: .localOnly
        )
        let seatTwo = makeUsage(sessionId: "session-2").attributingAccount(
            rawIdentity: "seat-two@example.com", label: "seat-two@example.com", source: .localOnly
        )
        try await store.insert(seatOne)
        try await store.insert(seatTwo)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(
            Set(rows.compactMap(\.providerAccountLabel)),
            ["seat-one@example.com", "seat-two@example.com"]
        )
    }

    /// The claim only takes unattributed rows. Two accounts that somehow share a
    /// session id must never be merged into one another.
    func testClaimNeverStealsAnotherAccountsRow() async throws {
        let store = try makeInMemoryDataStore()
        let seatOne = makeUsage().attributingAccount(
            rawIdentity: "seat-one@example.com", label: "seat-one@example.com", source: .localOnly
        )
        let seatTwo = makeUsage().attributingAccount(
            rawIdentity: "seat-two@example.com", label: "seat-two@example.com", source: .localOnly
        )
        try await store.insert(seatOne)
        try await store.insert(seatTwo)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 2, "A different account's row must not be claimed.")
    }

    func testUnattributedRowStillUpsertsInPlace() async throws {
        let store = try makeInMemoryDataStore()
        try await store.insert(makeUsage(inputTokens: 100))
        try await store.insert(makeUsage(inputTokens: 250))

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 250)
    }

    /// Per-account rollups are what the dashboard credential lane and the
    /// provider "Spend by Account" panel render.
    func testCredentialSummariesSplitByAccount() {
        let seatOne = makeUsage(sessionId: "s1").attributingAccount(
            rawIdentity: "seat-one@example.com", label: "seat-one@example.com", source: .localOnly
        )
        let seatTwo = makeUsage(sessionId: "s2").attributingAccount(
            rawIdentity: "seat-two@example.com", label: "seat-two@example.com", source: .localOnly
        )
        let legacy = makeUsage(sessionId: "s3")

        let summaries = UsageStore.makeCredentialSummaries(from: [seatOne, seatTwo, legacy])
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(
            summaries.first(where: { $0.accountLabel == "seat-one@example.com" })?.sessionCount, 1
        )
        XCTAssertNotNil(
            summaries.first(where: { $0.accountLabel.hasSuffix("default") }),
            "Legacy unattributed rows keep their own lane instead of being folded into a seat."
        )
    }

    // MARK: - Helpers

    private func makeInMemoryDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeUsage(
        sessionId: String = "session-1",
        inputTokens: Int = 100
    ) -> TokenUsage {
        TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "Project",
            model: "gpt-5",
            inputTokens: inputTokens,
            outputTokens: 20,
            costUSD: 0.25,
            startTime: Date(timeIntervalSince1970: 1_777_000_000),
            endTime: Date(timeIntervalSince1970: 1_777_003_600),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }
}
