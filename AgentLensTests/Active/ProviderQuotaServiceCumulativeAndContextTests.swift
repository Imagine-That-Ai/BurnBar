import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias ProviderQuotaBucket = OpenBurnBar.ProviderQuotaBucket
private typealias ProviderQuotaSnapshot = OpenBurnBar.ProviderQuotaSnapshot
private typealias ProviderQuotaWindowKind = OpenBurnBar.ProviderQuotaWindowKind

@MainActor
extension ProviderQuotaServiceTests {
    // MARK: - Cumulative across accounts
    //
    // Pure-logic tests against
    // `ProviderQuotaService.cumulativeSnapshot(provider:from:now:)`. The
    // service-level convenience method is a thin wrapper over this and
    // exercises the same code path.

    func test_cumulativeSnapshot_returnsNilForSingleAccount() {
        let snapshots = [
            makeSnapshot(
                accountID: "a1",
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours, used: 30, limit: 100)]
            )
        ]
        let result = ProviderQuotaService.cumulativeSnapshot(
            provider: .claudeCode,
            from: snapshots,
            now: now
        )
        XCTAssertNil(result)
    }

    func test_cumulativeSnapshot_sumsTwoAccountsByKeyAndWindowKind() throws {
        let snapshots = [
            makeSnapshot(
                accountID: "a1",
                fetchedAt: now.addingTimeInterval(-60),
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours, used: 30, limit: 100,
                               resetsAt: now.addingTimeInterval(3 * 60 * 60)),
                    makeBucket(key: "7d", windowKind: .weekly, used: 200, limit: 1000,
                               resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
                ]
            ),
            makeSnapshot(
                accountID: "a2",
                fetchedAt: now.addingTimeInterval(-30),
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours, used: 70, limit: 100,
                               resetsAt: now.addingTimeInterval(60 * 60)),
                    makeBucket(key: "7d", windowKind: .weekly, used: 500, limit: 1000,
                               resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60))
                ]
            )
        ]

        let result = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )

        XCTAssertEqual(result.accountLabel, "All accounts (2)")
        XCTAssertNil(result.accountID)
        XCTAssertEqual(result.buckets.count, 2)

        let hourly = try XCTUnwrap(result.hourlyBucket(relativeTo: now))
        XCTAssertEqual(hourly.usedValue, 100)
        XCTAssertEqual(hourly.limitValue, 200)
        XCTAssertEqual(try XCTUnwrap(hourly.usedPercent), 50, accuracy: 0.001)
        // Earliest resetsAt wins.
        XCTAssertEqual(hourly.resetsAt, now.addingTimeInterval(60 * 60))

        let weekly = try XCTUnwrap(result.weeklyBucket(relativeTo: now))
        XCTAssertEqual(weekly.usedValue, 700)
        XCTAssertEqual(weekly.limitValue, 2000)
        XCTAssertEqual(try XCTUnwrap(weekly.usedPercent), 35, accuracy: 0.001)
    }

    func test_cumulativeSnapshot_recomputesUsedPercentFromSums() throws {
        // 10% of 1000 + 90% of 100 should NOT average to 50%. The
        // weighted total is (100 + 90) / (1000 + 100) ≈ 17.27%.
        let snapshots = [
            makeSnapshot(
                accountID: "a1",
                fetchedAt: now,
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours,
                               used: 100, limit: 1000,
                               resetsAt: now.addingTimeInterval(60 * 60))
                ]
            ),
            makeSnapshot(
                accountID: "a2",
                fetchedAt: now,
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours,
                               used: 90, limit: 100,
                               resetsAt: now.addingTimeInterval(60 * 60))
                ]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        let hourly = try XCTUnwrap(merged.hourlyBucket(relativeTo: now))
        let hourlyUsedPercent = try XCTUnwrap(hourly.usedPercent)
        XCTAssertEqual(hourlyUsedPercent, 190.0 / 1100.0 * 100, accuracy: 0.01)
        XCTAssertNotEqual(hourlyUsedPercent, 50, accuracy: 1)
    }

    func test_cumulativeSnapshot_marksEstimatedIfAnyInputEstimated() throws {
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100, isEstimated: false,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100, isEstimated: true,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertTrue(try XCTUnwrap(merged.hourlyBucket(relativeTo: now)).isEstimated)
    }

    /// An isolated switcher profile is a real, separate login — its own
    /// `CODEX_HOME`/`CLAUDE_CONFIG_DIR`, its own quota. `fetchSwitcherProfileSnapshot`
    /// marks every one of them `.localOnly`, and the merge used to drop that
    /// whole scope, so two daemon accounts plus one switcher profile merged as
    /// two. The panel then reported an understated total under a confident
    /// "Combined 2 accounts" label — silently under-reporting spend.
    func test_cumulativeSnapshot_mergesIsolatedSwitcherProfileAccounts() throws {
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                scope: .cloudRefreshable,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                scope: .cloudRefreshable,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 20, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "switcher-profile", fetchedAt: now,
                scope: .localOnly,
                sourceID: "switcher-cli:codex:switcher-profile",
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 45, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]

        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(provider: .codex, from: snapshots, now: now)
        )
        let bucket = try XCTUnwrap(merged.hourlyBucket(relativeTo: now))

        XCTAssertEqual(bucket.usedValue, 95, "The switcher profile's 45 has to be part of the total, not dropped.")
        XCTAssertEqual(bucket.limitValue, 300)
        XCTAssertEqual(merged.mergedAccountCount, 3)
        XCTAssertEqual(merged.accountLabel, "All accounts (3)")
    }

    /// The one local record that must stay out of the sum: the synthetic
    /// "Current <CLI> login" is the provider-level rollup re-badged as an
    /// account, so adding it counts the same machine twice. With it removed
    /// only one real account remains, and a single account has nothing to merge.
    func test_cumulativeSnapshot_excludesTheSyntheticCurrentCLIMirror() {
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                scope: .cloudRefreshable,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "current-codex", fetchedAt: now,
                scope: .localOnly,
                sourceID: "switcher-cli-current:codex",
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 99, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]
        let merged = ProviderQuotaService.cumulativeSnapshot(
            provider: .codex,
            from: snapshots,
            now: now
        )
        XCTAssertNil(merged)
    }

    func test_cumulativeSnapshot_mixedWindowKinds() throws {
        // a1 has only 5h, a2 has only 7d. Cumulative emits both buckets,
        // each summed across its own account (which is just that account).
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 40, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                buckets: [makeBucket(key: "7d", windowKind: .weekly,
                                      used: 50, limit: 100,
                                      resetsAt: now.addingTimeInterval(86400))]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertEqual(merged.buckets.count, 2)
        XCTAssertNotNil(merged.hourlyBucket(relativeTo: now))
        XCTAssertNotNil(merged.weeklyBucket(relativeTo: now))
    }

    func test_cumulativeSnapshot_picksEarliestResetsAt() throws {
        let later = now.addingTimeInterval(4 * 60 * 60)
        let earlier = now.addingTimeInterval(60 * 60)
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100, resetsAt: later)]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 70, limit: 100, resetsAt: earlier)]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertEqual(try XCTUnwrap(merged.hourlyBucket(relativeTo: now)).resetsAt, earlier)
    }

    func test_cumulativeSnapshot_staleFallbackWhenAllAccountsStale() throws {
        // Both snapshots fetched > 12h ago — `isStale` will return true
        // for each. The result should be the freshest single snapshot
        // wrapped with a "Stale data merged" status and unavailable
        // confidence.
        let veryOld = now.addingTimeInterval(-13 * 60 * 60)
        let slightlyLessOld = now.addingTimeInterval(-12 * 60 * 60 - 60)
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: veryOld,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: slightlyLessOld,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 70, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertEqual(merged.confidence, .unavailable)
        XCTAssertEqual(merged.statusMessage?.contains("Stale"), true)
    }

    // MARK: - Multi-account readiness: shared daemon provider map

    /// The fetch path and the `ProviderAccountDoc` projection used to keep
    /// separate copies of this map, and the projection's copy was missing xAI —
    /// xAI credential slots produced per-account quota snapshots that never
    /// became accounts. There is exactly one copy now; this pins its contents.
    func test_quotaCapableProviderMap_coversEveryMultiAccountDaemonProvider() {
        let expected: [String: AgentProvider] = [
            "minimax": .minimax,
            "zai": .zai,
            "z-ai": .zai,
            "ollama": .ollama,
            "openai": .openAI,
            "anthropic": .claudeCode,
            "claude": .claudeCode,
            "claude-code": .claudeCode,
            "opencode": .openCode,
            "deepseek": .deepSeek,
            "moonshot": .kimi,
            "kimi": .kimi,
            "xai": .xAI,
            "x-ai": .xAI,
            "grok": .xAI
        ]
        for (providerID, provider) in expected {
            XCTAssertEqual(
                QuotaCapableProviderMap.provider(forDaemonProviderID: providerID),
                provider,
                "daemon providerID \(providerID) should map to \(provider)"
            )
        }
        XCTAssertNil(QuotaCapableProviderMap.provider(forDaemonProviderID: "not-a-provider"))
    }

    /// OpenAI's usage endpoint is organization-scoped, so every credential slot
    /// would report identical numbers. It must stay provider-level or the
    /// cumulative merge multiplies one org's usage by its key count.
    func test_quotaCapableProviderMap_marksOpenAIOrganizationScoped() {
        XCTAssertFalse(QuotaCapableProviderMap.supportsPerAccountQuota(.openAI))
        XCTAssertTrue(QuotaCapableProviderMap.supportsPerAccountQuota(.claudeCode))
        XCTAssertTrue(QuotaCapableProviderMap.supportsPerAccountQuota(.xAI))
    }

    /// Recognising an alias is only half the job. Accepting `x-ai` while
    /// letting the raw alias ride along on the account identity produced a
    /// configuration that quota-fetched fine and was still invisible: the two
    /// consumers below only ever look for the canonical id.
    func test_canonicalProviderID_rewritesEveryAliasToTheProvidersOwnID() {
        for alias in ["xai", "x-ai", "x.ai", "grok"] {
            XCTAssertEqual(
                QuotaCapableProviderMap.canonicalProviderID(forDaemonProviderID: alias),
                ProviderID.xAI,
                "daemon providerID \(alias) must resolve to the canonical xAI id"
            )
        }
        XCTAssertEqual(
            QuotaCapableProviderMap.canonicalProviderID(forDaemonProviderID: "anthropic"),
            AgentProvider.claudeCode.providerID
        )
        XCTAssertEqual(
            QuotaCapableProviderMap.canonicalProviderID(forDaemonProviderID: "moonshot"),
            AgentProvider.kimi.providerID
        )
    }

    /// An unmapped provider keeps the id it was configured with — canonicalizing
    /// must not invent identities for providers this map knows nothing about.
    func test_canonicalProviderID_passesUnmappedProvidersThrough() {
        XCTAssertEqual(
            QuotaCapableProviderMap.canonicalProviderID(forDaemonProviderID: "mistral"),
            ProviderID(rawValue: "mistral")
        )
    }

    /// Consumer 1: `connectedQuotaProviderIDs` resolves a projected account
    /// through `AgentProvider.fromProviderID`, which knows only canonical ids.
    /// An `x-ai` slot therefore produced no connected xAI provider at all.
    func test_daemonSlotProjection_canonicalizesAliasConfiguredProviders() throws {
        let accounts = DaemonCredentialSlotAccountProjection.accounts(
            from: [Self.makeSlotConfiguration(providerID: "x-ai", slotID: "team")],
            now: now
        )

        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.providerID, ProviderID.xAI)
        XCTAssertEqual(account.id, "xai-team")
        XCTAssertEqual(
            AgentProvider.fromProviderID(account.providerID),
            .xAI,
            "The projected account has to resolve back to a provider, or it is invisible to every quota surface."
        )
    }

    /// Consumer 2: `snapshots(for:)` searches the canonical id, so the account
    /// snapshot has to be stored under it. `snapshotProviderIDs` still accepts
    /// the aliases for records written before this was true.
    func test_snapshotsForProvider_findsAccountsStoredUnderTheCanonicalID() {
        let service = ProviderQuotaService(refreshProviders: [])
        for snapshot in [
            makeSnapshot(
                provider: .xAI, accountID: "xai-team",
                sourceID: "daemon-slot:xai:team",
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours, used: 10, limit: 100, resetsAt: nil)]
            ),
            // Legacy record persisted under the alias, before canonicalization.
            ProviderQuotaSnapshot(
                provider: .xAI,
                providerID: ProviderID(rawValue: "x-ai"),
                accountID: "x-ai-legacy",
                accountLabel: "Legacy",
                accountStorageScope: .deviceKeychain,
                fetchedAt: now,
                source: .officialAPI,
                sourceId: "daemon-slot:x-ai:legacy",
                confidence: .exact,
                managementURL: nil,
                statusMessage: "ok",
                buckets: []
            )
        ] {
            service.snapshotsByAccountID[ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot)] = snapshot
        }

        XCTAssertEqual(
            Set(service.snapshots(for: AgentProvider.xAI).compactMap(\.accountID)),
            ["xai-team", "x-ai-legacy"]
        )
    }

    /// Canonicalizing renames an existing identity, so the sweep has to retire
    /// the row written under the old one. Without that, an upgrading user with
    /// an `anthropic` slot sees the same credential twice: the stale
    /// `anthropic-gmail` row beside its `claude-code-gmail` replacement.
    func test_persistDaemonSlotAccounts_retiresThePreCanonicalizationRow() async throws {
        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            Self.makeSlotConfiguration(providerID: "anthropic", slotID: "gmail")
        ]
        let dataStore = try makeDataStore()
        try await dataStore.upsertProviderAccount(
            ProviderAccountDoc(
                id: "anthropic-gmail",
                providerID: ProviderID(rawValue: "anthropic"),
                label: "gmail",
                identityHint: "Daemon credential slot",
                status: .connected,
                credentialKind: .bearer,
                storageScope: .deviceKeychain,
                redactedLabel: "Stored in Mac Keychain",
                schemaVersion: 1,
                createdAt: now,
                updatedAt: now
            )
        )

        await ProviderQuotaService(refreshProviders: []).persistDaemonCredentialSlotAccounts(dataStore: dataStore)

        let canonical = try await dataStore.fetchProviderAccounts(providerID: AgentProvider.claudeCode.providerID)
        let legacy = try await dataStore.fetchProviderAccounts(providerID: ProviderID(rawValue: "anthropic"))

        XCTAssertEqual(canonical.map(\.id), ["claude-code-gmail"])
        XCTAssertEqual(canonical.map(\.status), [.connected])
        XCTAssertEqual(legacy.map(\.status), [.deleted])
    }

    /// The alias set is what lets the sweep retire records written under the
    /// old identity instead of leaving them beside their canonical replacement.
    func test_daemonProviderIDs_coverTheCanonicalIDAndEveryAlias() {
        XCTAssertEqual(
            QuotaCapableProviderMap.daemonProviderIDs(for: .xAI),
            Set(["xai", "x-ai", "x.ai", "grok"].map { ProviderID(rawValue: $0) })
        )
        XCTAssertTrue(
            QuotaCapableProviderMap.daemonProviderIDs(for: .claudeCode).contains(ProviderID.anthropic)
        )
        XCTAssertEqual(
            QuotaCapableProviderMap.daemonProviderIDs(for: .factory),
            [AgentProvider.factory.providerID],
            "A provider with no daemon aliases still answers with its own id."
        )
    }

    private static func makeSlotConfiguration(
        providerID: String,
        slotID: String
    ) -> OpenBurnBarDaemonProviderConfiguration {
        OpenBurnBarDaemonProviderConfiguration(
            providerID: providerID,
            provider: nil,
            displayName: providerID,
            isEnabled: true,
            baseURL: "https://\(providerID).example/v1",
            preferredModelIDs: [],
            preferredCredentialSlotID: slotID,
            credentialSlots: [
                OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                    slotID: slotID,
                    label: "Team key",
                    isEnabled: true,
                    status: .ready,
                    cooldownUntil: nil,
                    lastSelectedAt: nil,
                    lastQuotaRemainingPercent: nil,
                    lastQuotaResetsAt: nil,
                    lastStatusMessage: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
                )
            ]
        )
    }

    // MARK: - Multi-account readiness: account display naming

    func test_accountDisplayLabel_prefersAccountLabelThenAccountID() {
        let labelled = makeSnapshot(accountID: "a1", buckets: [])
        XCTAssertEqual(
            ProviderQuotaAccountDisplay.label(for: labelled, provider: .claudeCode),
            "Account a1"
        )

        let idOnly = ProviderQuotaSnapshot(
            provider: .claudeCode,
            accountID: "slot-2",
            fetchedAt: now,
            source: .officialAPI,
            sourceId: "daemon-slot:anthropic:slot-2",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: []
        )
        XCTAssertEqual(
            ProviderQuotaAccountDisplay.label(for: idOnly, provider: .claudeCode),
            "slot-2"
        )
    }

    /// A provider rollup carries `sourceId == "default"`, which every surface
    /// used to render verbatim as the account name.
    func test_accountDisplayLabel_neverSurfacesTheLiteralDefaultSourceID() {
        let rollup = ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: []
        )
        XCTAssertEqual(rollup.sourceId, "default")
        XCTAssertTrue(ProviderQuotaAccountDisplay.isRollup(rollup))
        XCTAssertEqual(
            ProviderQuotaAccountDisplay.label(for: rollup, provider: .claudeCode),
            "Default login"
        )
        XCTAssertEqual(
            ProviderQuotaAccountDisplay.label(for: rollup, provider: .openAI),
            "Organization · all keys"
        )
    }

    func test_accountDisplayLabel_recognisesTheSyntheticMergedSnapshot() throws {
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: [
                    makeSnapshot(accountID: "a1", buckets: [makeBucket(key: "5h", windowKind: .rollingHours, used: 10, limit: 100)]),
                    makeSnapshot(accountID: "a2", buckets: [makeBucket(key: "5h", windowKind: .rollingHours, used: 20, limit: 100)])
                ],
                now: now
            )
        )
        XCTAssertTrue(ProviderQuotaAccountDisplay.isMerged(merged))
        XCTAssertFalse(ProviderQuotaAccountDisplay.isRollup(merged))
        XCTAssertEqual(
            ProviderQuotaAccountDisplay.label(for: merged, provider: .claudeCode),
            "All accounts (2)"
        )
    }

    // MARK: - Multi-account readiness: per-account snapshot identity

    /// `withAccountMetadata` used to copy the base snapshot's `id` through, so
    /// every account of a provider carried `claude-code_default` and any
    /// `ForEach` over them without an explicit key collapsed to one row.
    func test_withAccountMetadata_givesEachAccountItsOwnIdentifiableID() {
        let base = ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: []
        )
        let first = base.withAccountMetadata(
            providerID: AgentProvider.claudeCode.providerID,
            accountID: "work",
            accountLabel: "Work",
            accountStorageScope: .deviceKeychain,
            sourceId: "daemon-slot:anthropic:work"
        )
        let second = base.withAccountMetadata(
            providerID: AgentProvider.claudeCode.providerID,
            accountID: "personal",
            accountLabel: "Personal",
            accountStorageScope: .deviceKeychain,
            sourceId: "daemon-slot:anthropic:personal"
        )

        XCTAssertNotEqual(first.id, base.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set([first, second].map(\.id)).count, 2)
    }

    // MARK: Cumulative-test fixtures

    /// Reference clock used by the cumulative tests above. Fixed so
    /// `isStale` boundaries are deterministic.
    private var now: Date {
        Date(timeIntervalSince1970: 1_750_000_000)
    }

    private func makeBucket(
        key: String,
        windowKind: ProviderQuotaWindowKind,
        used: Double,
        limit: Double,
        isEstimated: Bool = false,
        resetsAt: Date? = nil
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: key,
            windowKind: windowKind,
            usedValue: used,
            limitValue: limit,
            remainingValue: max(limit - used, 0),
            usedPercent: limit > 0 ? min(max(used / limit * 100, 0), 100) : nil,
            resetsAt: resetsAt,
            unit: .tokens,
            isEstimated: isEstimated
        )
    }

    private func makeSnapshot(
        provider: AgentProvider = .claudeCode,
        accountID: String,
        fetchedAt: Date? = nil,
        scope: ProviderAccountStorageScope = .cloudRefreshable,
        sourceID: String? = nil,
        buckets: [ProviderQuotaBucket]
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            providerID: provider.providerID,
            accountID: accountID,
            accountLabel: "Account \(accountID)",
            accountStorageScope: scope,
            fetchedAt: fetchedAt ?? now,
            source: .officialAPI,
            sourceId: sourceID ?? accountID,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: buckets
        )
    }

    // MARK: - Claude context-window quota-boundary tests

    /// Writes a Claude statusline snapshot that contains `context_window`
    /// data but NO `rate_limits` key, plus the Claude settings needed for
    /// the bridge to report `.ready`.
    func writeContextWindowOnlyFixture(
        home: URL,
        appPaths: OpenBurnBar.OpenBurnBarAppPaths,
        fiveHourUsedPercent: Int? = nil,
        usedPercentage: Int = 26,
        windowSize: Int = 1_000_000,
        inputTokens: Int = 264_134,
        outputTokens: Int = 491,
        sessionName: String = "Fix loginwindow keystroke delivery",
        modelName: String = "Opus 4.8 (1M context)",
        costUSD: Double = 79.66,
        stale: Bool = false
    ) throws {
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rateLimits: String
        if let fiveHourUsedPercent {
            rateLimits = """
              "rate_limits": {
                "five_hour": { "used_percentage": \(fiveHourUsedPercent), "resets_at": "2026-03-24T15:00:00Z" }
              },
            """
        } else {
            rateLimits = ""
        }
        let payload = """
        {
        \(rateLimits)
          "session_name": "\(sessionName)",
          "model": { "id": "claude-opus-4-8", "display_name": "\(modelName)" },
          "cost": { "total_cost_usd": \(costUSD) },
          "context_window": {
            "total_input_tokens": \(inputTokens),
            "total_output_tokens": \(outputTokens),
            "context_window_size": \(windowSize),
            "used_percentage": \(usedPercentage),
            "remaining_percentage": \(100 - usedPercentage)
          }
        }
        """
        try Data(payload.utf8).write(to: snapshotURL)

        if stale {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-60 * 60)],
                ofItemAtPath: snapshotURL.path
            )
        }

        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let settings = """
        {
          "statusLine": {
            "type": "command",
            "command": "\(appPaths.claudeStatuslineBridgeScriptURL.path)"
          }
        }
        """
        try Data(settings.utf8).write(to: settingsURL)
    }

    func test_claudeRefresh_contextWindowOnlySnapshotDoesNotRenderAsQuota() async throws {
        let home = try makeSplitTemporaryDirectory()
        let appSupport = try makeSplitTemporaryDirectory()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        try writeContextWindowOnlyFixture(home: home, appPaths: appPaths)

        let service = makeSplitService(home: home, appSupportRoot: appSupport)
        await service.refresh(provider: .claudeCode, dataStore: try makeSplitDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.provider, AgentProvider.claudeCode.rawValue)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertNotEqual(snapshot.statusMessage?.contains("Context window"), true)
    }

    func test_claudeRefresh_staleContextWindowOnlySnapshotDoesNotRenderAsQuota() async throws {
        let home = try makeSplitTemporaryDirectory()
        let appSupport = try makeSplitTemporaryDirectory()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        try writeContextWindowOnlyFixture(home: home, appPaths: appPaths, stale: true)

        let service = makeSplitService(home: home, appSupportRoot: appSupport)
        await service.refresh(provider: .claudeCode, dataStore: try makeSplitDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertNotEqual(snapshot.statusMessage?.contains("context window"), true)
    }

    func test_claudeRefresh_statuslineRateLimitsWinEvenWhenContextWindowIsPresent() async throws {
        let home = try makeSplitTemporaryDirectory()
        let appSupport = try makeSplitTemporaryDirectory()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        // Write a fixture that has BOTH rate_limits and context_window
        try writeContextWindowOnlyFixture(
            home: home,
            appPaths: appPaths,
            fiveHourUsedPercent: 42
        )

        let service = makeSplitService(home: home, appSupportRoot: appSupport)
        await service.refresh(provider: .claudeCode, dataStore: try makeSplitDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.key != "context-window" }),
                       "When rate_limits is present, primary path should produce standard quota buckets")
        XCTAssertFalse(snapshot.buckets.contains(where: { $0.key == "context-window" }),
                        "Context-window telemetry must not render as quota")
    }

    private func makeSplitTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeSplitDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeSplitService(
        home: URL,
        appSupportRoot: URL
    ) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: ProviderAPIKeyStore(
                keychain: KeychainStore(
                    service: "tests.split.\(UUID().uuidString)",
                    legacyServices: [],
                    backend: ProviderQuotaSplitKeychainBackend()
                )
            ),
            providerRuntimeKeyStore: KeychainStore(
                service: "tests.split.runtime.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaSplitKeychainBackend()
            ),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: .shared,
            environment: [:],
            homeDirectoryURL: home,
            miniMaxModeProvider: { .payAsYouGo },
            factoryPlanProvider: { .unknown },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            refreshProviders: ProviderQuotaService.supportedProviders
        )
    }
}

private final class ProviderQuotaSplitKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}
