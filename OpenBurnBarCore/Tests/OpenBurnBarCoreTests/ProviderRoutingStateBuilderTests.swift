import XCTest
@testable import OpenBurnBarCore

/// Behavior contract for the routing-state builder that powers the
/// quota-aware routing cockpit on Mobile/iPad and any future remote dashboard.
/// The builder must produce the same active lane as the Mac router for the
/// same inputs, never expose secret material, and stay deterministic across
/// platform launches.
final class ProviderRoutingStateBuilderTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Empty / trivial cases

    func test_build_returnsNil_whenNoAccountsAreEligible() {
        XCTAssertNil(ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [],
            snapshots: [],
            now: now
        ))
    }

    func test_build_returnsNil_whenAllAccountsAreDeleted() {
        let deleted = account(id: "openai_legacy", status: .deleted)
        XCTAssertNil(ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [deleted],
            snapshots: [],
            now: now
        ))
    }

    func test_build_filtersAccountsByProvider() {
        let openAI = account(id: "openai_work", providerID: .openAI)
        let claude = account(id: "claude_work", providerID: .claudeCode)

        let snapshot = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [openAI, claude],
            snapshots: [],
            now: now
        )

        XCTAssertEqual(snapshot?.activeAccount?.accountID, "openai_work")
        XCTAssertNil(snapshot?.nextFallback)
    }

    // MARK: - Active lane selection

    func test_build_promotesDefaultAccountToActiveLane() {
        let work = account(id: "openai_work", isDefault: false, sortKey: 10)
        let personal = account(id: "openai_personal", isDefault: true, sortKey: 20)

        let snapshot = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [work, personal],
            snapshots: [healthySnapshot(accountID: "openai_personal"), healthySnapshot(accountID: "openai_work")],
            now: now
        )

        XCTAssertEqual(snapshot?.activeAccount?.accountID, "openai_personal")
        XCTAssertEqual(snapshot?.nextFallback?.accountID, "openai_work")
    }

    func test_build_isDeterministicAcrossEqualSortKeys() {
        let bravo = account(id: "openai_b", label: "Bravo", sortKey: 5)
        let alpha = account(id: "openai_a", label: "Alpha", sortKey: 5)

        let firstRun = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [bravo, alpha],
            snapshots: [],
            now: now
        )
        let secondRun = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [alpha, bravo],
            snapshots: [],
            now: now
        )

        XCTAssertEqual(firstRun?.activeAccount?.accountID, "openai_a")
        XCTAssertEqual(secondRun?.activeAccount?.accountID, "openai_a")
    }

    // MARK: - Quota → routing state mapping

    func test_quotaState_mapsExhaustedSnapshotToExhaustedLane() {
        let acc = account(id: "openai_work")
        let exhausted = ProviderQuotaSnapshot(
            id: "snap",
            provider: "openai",
            providerID: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            sourceKind: .provider,
            sourceId: "openai_work",
            fetchedAt: now,
            source: "OpenAI",
            confidence: .high,
            buckets: [ProviderQuotaBucket(name: "tokens", used: 1_000_000, limit: 1_000_000, remaining: 0)],
            updatedAt: now
        )

        XCTAssertEqual(
            ProviderRoutingStateBuilder.quotaState(for: acc, snapshot: exhausted),
            .exhausted
        )
    }

    func test_quotaState_mapsLowestRemainingBucketToPressure() {
        let acc = account(id: "openai_work")
        let snapshot = ProviderQuotaSnapshot(
            id: "snap",
            provider: "openai",
            providerID: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            sourceKind: .provider,
            sourceId: "openai_work",
            fetchedAt: now,
            source: "OpenAI",
            confidence: .high,
            // Tokens look fine, but requests-per-day is at 5%.
            buckets: [
                ProviderQuotaBucket(name: "tokens", used: 100_000, limit: 1_000_000, remaining: 900_000),
                ProviderQuotaBucket(name: "requests", used: 950, limit: 1_000, remaining: 50)
            ],
            updatedAt: now
        )

        XCTAssertEqual(
            ProviderRoutingStateBuilder.quotaState(for: acc, snapshot: snapshot),
            .pressure
        )
    }

    func test_quotaState_mapsErrorAndDisconnectedToAuthFailed() {
        let errored = account(id: "a", status: .error, lastErrorCode: "auth_invalid")
        let disconnected = account(id: "b", status: .disconnected)

        XCTAssertEqual(ProviderRoutingStateBuilder.quotaState(for: errored, snapshot: nil), .authFailed)
        XCTAssertEqual(ProviderRoutingStateBuilder.quotaState(for: disconnected, snapshot: nil), .authFailed)
    }

    func test_quotaState_mapsDisabledAndDeletedToTheirOwnLanes() {
        XCTAssertEqual(
            ProviderRoutingStateBuilder.quotaState(for: account(id: "x", status: .disabled), snapshot: nil),
            .disabled
        )
        XCTAssertEqual(
            ProviderRoutingStateBuilder.quotaState(for: account(id: "y", status: .deleted), snapshot: nil),
            .deleted
        )
    }

    func test_quotaState_treatsStaleSnapshotsAsPressure() {
        let acc = account(id: "openai_work")
        let stale = ProviderQuotaSnapshot(
            id: "snap",
            provider: "openai",
            providerID: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            sourceKind: .provider,
            sourceId: "openai_work",
            fetchedAt: now,
            source: "OpenAI",
            confidence: .stale,
            buckets: [ProviderQuotaBucket(name: "tokens", used: 100_000, limit: 1_000_000, remaining: 900_000)],
            updatedAt: now
        )

        XCTAssertEqual(
            ProviderRoutingStateBuilder.quotaState(for: acc, snapshot: stale),
            .pressure
        )
    }

    // MARK: - Snapshot freshness

    func test_build_picksMostRecentSnapshotPerAccount() {
        // Older snapshot says "exhausted"; newer says "healthy". The cockpit
        // must trust the newer one rather than whatever ordering the caller
        // happened to use.
        let acc = account(id: "openai_work")
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)
        let stale = ProviderQuotaSnapshot(
            id: "snap_old",
            provider: "openai",
            providerID: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            sourceKind: .provider,
            sourceId: "openai_work",
            fetchedAt: yesterday,
            source: "OpenAI",
            confidence: .high,
            buckets: [ProviderQuotaBucket(name: "tokens", used: 1, limit: 1, remaining: 0)],
            updatedAt: yesterday
        )
        let fresh = healthySnapshot(accountID: "openai_work")

        let snapshot = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [acc],
            // Deliberately put the stale snapshot first to verify ordering
            // doesn't matter.
            snapshots: [stale, fresh],
            now: now
        )

        XCTAssertEqual(snapshot?.activeAccount?.quotaState, .healthy)
        XCTAssertTrue(snapshot?.exhaustedOrCoolingDownAccounts.isEmpty ?? false)
    }

    // MARK: - Blocked lane

    func test_build_surfacesExhaustedAndCoolingDownAccountsAsBlocked() {
        let work = account(id: "openai_work")
        let personal = account(id: "openai_personal")
        let exhaustedWork = ProviderQuotaSnapshot(
            id: "snap_work",
            provider: "openai",
            providerID: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            sourceKind: .provider,
            sourceId: "openai_work",
            fetchedAt: now,
            source: "OpenAI",
            confidence: .high,
            buckets: [ProviderQuotaBucket(name: "tokens", used: 1_000_000, limit: 1_000_000, remaining: 0)],
            updatedAt: now
        )

        let snapshot = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [work, personal],
            snapshots: [exhaustedWork, healthySnapshot(accountID: "openai_personal")],
            now: now
        )

        XCTAssertEqual(snapshot?.activeAccount?.accountID, "openai_personal")
        XCTAssertEqual(snapshot?.exhaustedOrCoolingDownAccounts.map(\.accountID), ["openai_work"])
    }

    // MARK: - Security boundary

    func test_build_neverEmitsRawCredentialMaterialIntoEvents() throws {
        let leaky = account(
            id: "openai_work",
            redactedLabel: "secretVersionName=projects/p/secrets/s/versions/3",
            lastErrorCode: "Authorization: Bearer abcdef123456"
        )

        let snapshot = try XCTUnwrap(ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [leaky],
            snapshots: [],
            now: now
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = String(decoding: try encoder.encode(snapshot), as: UTF8.self)

        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("secretVersionName"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("Bearer abcdef123456"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("projects/p/secrets"))
    }

    // MARK: - hasMeaningfulRoutingDetail

    func test_hasMeaningfulRoutingDetail_isFalseForLoneHealthyAccount() {
        let single = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [account(id: "openai_only")],
            snapshots: [healthySnapshot(accountID: "openai_only")],
            now: now
        )
        XCTAssertEqual(single?.activeAccount?.accountID, "openai_only")
        XCTAssertFalse(single?.hasMeaningfulRoutingDetail ?? true)
    }

    func test_hasMeaningfulRoutingDetail_isTrueWhenFallbackExists() {
        let multi = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [account(id: "a", isDefault: true), account(id: "b")],
            snapshots: [healthySnapshot(accountID: "a"), healthySnapshot(accountID: "b")],
            now: now
        )
        XCTAssertTrue(multi?.hasMeaningfulRoutingDetail ?? false)
    }

    func test_hasMeaningfulRoutingDetail_isTrueWhenAccountIsBlocked() {
        let exhausted = ProviderQuotaSnapshot(
            id: "snap",
            provider: "openai",
            providerID: .openAI,
            accountID: "a",
            accountLabel: "A",
            sourceKind: .provider,
            sourceId: "a",
            fetchedAt: now,
            source: "OpenAI",
            confidence: .high,
            buckets: [ProviderQuotaBucket(name: "tokens", used: 1, limit: 1, remaining: 0)],
            updatedAt: now
        )
        let snapshot = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [account(id: "a")],
            snapshots: [exhausted],
            now: now
        )
        XCTAssertTrue(snapshot?.hasMeaningfulRoutingDetail ?? false)
    }

    func test_build_synthesizesNonSecretCredentialHandleWhenRedactedLabelEmpty() {
        // Empty redacted label must not cause `.missingCredential` skip — the
        // builder synthesizes a stable, non-secret sentinel from the account
        // ID. The cockpit never renders it.
        let acc = account(id: "openai_work", redactedLabel: "")

        let snapshot = ProviderRoutingStateBuilder.build(
            providerID: .openAI,
            accounts: [acc],
            snapshots: [healthySnapshot(accountID: "openai_work")],
            now: now
        )

        XCTAssertEqual(snapshot?.activeAccount?.accountID, "openai_work")
        XCTAssertFalse(snapshot?.activeAccount?.credentialHandle.contains("sk-") ?? false)
        XCTAssertFalse(snapshot?.activeAccount?.credentialHandle.contains("Bearer") ?? false)
    }

    // MARK: - Helpers

    private func account(
        id: String,
        providerID: ProviderID = .openAI,
        label: String? = nil,
        status: ProviderAccountStatus = .connected,
        isDefault: Bool = false,
        sortKey: Double = 0,
        redactedLabel: String = "sk-***abcd",
        lastErrorCode: String? = nil
    ) -> ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: providerID,
            label: label ?? id.replacingOccurrences(of: "_", with: " ").capitalized,
            identityHint: nil,
            status: status,
            credentialKind: .bearer,
            storageScope: .deviceKeychain,
            redactedLabel: redactedLabel,
            sourceDeviceID: "mac-1",
            linkedSwitcherProfileID: nil,
            isDefault: isDefault,
            sortKey: sortKey,
            lastValidatedAt: now,
            lastRefreshAt: now,
            lastErrorCode: lastErrorCode,
            schemaVersion: 1,
            createdAt: now,
            updatedAt: now
        )
    }

    private func healthySnapshot(accountID: String) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "snap_\(accountID)",
            provider: "openai",
            providerID: .openAI,
            accountID: accountID,
            accountLabel: accountID,
            sourceKind: .provider,
            sourceId: accountID,
            fetchedAt: now,
            source: "OpenAI",
            confidence: .high,
            buckets: [ProviderQuotaBucket(name: "tokens", used: 100_000, limit: 1_000_000, remaining: 900_000)],
            updatedAt: now
        )
    }
}
