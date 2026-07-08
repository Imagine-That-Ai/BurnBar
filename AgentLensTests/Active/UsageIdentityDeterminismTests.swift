import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

@MainActor
final class UsageIdentityDeterminismTests: XCTestCase {
    private func makeStore() throws -> DataStore {
        try makeDiscoveryInMemoryStore()
    }

    private func usage(
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        costUSD: Double = 0.01,
        startTime: Date = Date(timeIntervalSince1970: 1_700_000_000),
        providerAccountID: String? = "acct-raw-work"
    ) -> TokenUsage {
        TokenUsage(
            provider: .claudeCode,
            sessionId: "stable-session",
            projectName: "StableProject",
            model: "claude-3-5-sonnet",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(60),
            providerAccountID: providerAccountID,
            provenanceConfidence: .exact
        )
    }

    func test_tokenUsageDefaultID_isDeterministicForSQLiteConflictKey() {
        let first = usage(inputTokens: 100, costUSD: 0.01)
        let reparsed = usage(inputTokens: 250, costUSD: 0.04)
        let partition = TokenUsage.providerAccountIdentityPartition(from: "acct-raw-work")

        XCTAssertEqual(first.id, reparsed.id)
        XCTAssertEqual(partition, "acct_sha256_426e3e05f0f5775ef36b5f5e")
        XCTAssertEqual(
            first.id,
            TokenUsage.deterministicID(
                provider: .claudeCode,
                sessionId: "stable-session",
                model: "claude-3-5-sonnet",
                providerAccountID: partition
            )
        )
    }

    func test_usageStoreUpsert_sameConflictKeyKeepsOneDeterministicRow() async throws {
        let store = try makeStore()
        try await store.insert(usage(inputTokens: 100, outputTokens: 50, costUSD: 0.01))
        try await store.insert(usage(inputTokens: 300, outputTokens: 75, costUSD: 0.05))

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, usage().id)
        XCTAssertEqual(rows[0].providerAccountID, TokenUsage.providerAccountIdentityPartition(from: "acct-raw-work"))
        XCTAssertEqual(rows[0].inputTokens, 300)
        XCTAssertEqual(rows[0].outputTokens, 75)
        XCTAssertEqual(rows[0].cost, 0.05, accuracy: 0.000001)
    }

    func test_recountStyleDeleteAndReparse_regeneratesSameUsageID() async throws {
        let store = try makeStore()
        let parsedBeforeRecount = usage()
        try await store.insert(parsedBeforeRecount)
        try await store.deleteAll()

        let parsedAfterRecount = usage()
        try await store.insert(parsedAfterRecount)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, parsedBeforeRecount.id)
        XCTAssertEqual(parsedAfterRecount.id, parsedBeforeRecount.id)
    }

    func test_tokenUsageDefaultID_partitionsBySourceDeviceAndAccount() {
        let local = usage(providerAccountID: "acct-raw-work")
        let otherAccount = usage(providerAccountID: "acct-raw-personal")
        let remoteSource = TokenUsage(
            provider: .claudeCode,
            sessionId: "stable-session",
            projectName: "StableProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_060),
            sourceDeviceId: "remote-device-1",
            providerAccountID: "acct-raw-work",
            provenanceConfidence: .exact
        )

        XCTAssertNotEqual(local.id, otherAccount.id)
        XCTAssertNotEqual(local.id, remoteSource.id)
    }
}
