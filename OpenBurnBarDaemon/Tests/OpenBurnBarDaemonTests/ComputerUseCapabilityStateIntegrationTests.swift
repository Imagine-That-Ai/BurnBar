import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseCapabilityStateIntegrationTests: XCTestCase {
    func testMissingAndStaleStateFailClosed() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = temporaryDirectory().appendingPathComponent("capability-state.json")
        let store = ComputerUseCapabilityStateStore(fileURL: url, maximumAge: 60, now: { now })

        do {
            _ = try await store.currentState()
            XCTFail("Expected missing state to fail closed")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .missing)
        }

        _ = try await store.update(makeState(revision: 1, generatedAt: now))
        let staleStore = ComputerUseCapabilityStateStore(
            fileURL: url,
            maximumAge: 60,
            now: { now.addingTimeInterval(61) }
        )
        do {
            _ = try await staleStore.currentState()
            XCTFail("Expected stale state to fail closed")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .stale)
        }
    }

    func testPersistedRevisionRejectsRollback() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = temporaryDirectory().appendingPathComponent("capability-state.json")
        let first = ComputerUseCapabilityStateStore(fileURL: url, now: { now })
        _ = try await first.update(makeState(revision: 2, generatedAt: now))

        let reloaded = ComputerUseCapabilityStateStore(fileURL: url, now: { now })
        do {
            _ = try await reloaded.update(makeState(revision: 1, generatedAt: now))
            XCTFail("Expected persisted revision rollback to be refused")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .rolledBack)
        }
    }

    func testCurrentPublicationReplacesUnsupportedPersistedSchema() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("capability-state.json")
        try #"{"schemaVersion":1,"state":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        let store = ComputerUseCapabilityStateStore(fileURL: url, now: { now })

        let response = try await store.update(makeState(revision: 1, generatedAt: now))

        XCTAssertTrue(response.accepted)
        let current = try await store.currentState()
        XCTAssertEqual(current.schemaVersion, ComputerUseCapabilityStateSnapshot.currentSchemaVersion)
    }

    func testMalformedNegativeQuotaStateIsRejected() async throws {
        let store = makeStore()
        do {
            _ = try await store.update(makeState(revision: 1, actionsExecuted: -1))
            XCTFail("Expected malformed negative quota state to be refused")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .invalid)
        }
    }

    func testCompleteStateForWrongUTCDayFailsClosed() async throws {
        let store = makeStore()
        do {
            _ = try await store.update(makeState(revision: 1, quotaDayKey: "2027-01-14"))
            XCTFail("Expected a previous-day quota snapshot to fail closed")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .wrongQuotaDay)
        }
    }

    func testSessionStartDeniesMissingState() async throws {
        let service = makeService(store: makeStore())
        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected missing capability state to deny session admission")
        } catch let error as ComputerUseService.ServiceError {
            guard case .capabilityStateUnavailable = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testSessionStartDeniesStaleState() async throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let url = temporaryDirectory().appendingPathComponent("capability-state.json")
        let currentStore = ComputerUseCapabilityStateStore(
            fileURL: url,
            maximumAge: 60,
            now: { generatedAt }
        )
        _ = try await currentStore.update(makeState(revision: 1, generatedAt: generatedAt))
        let staleStore = ComputerUseCapabilityStateStore(
            fileURL: url,
            maximumAge: 60,
            now: { generatedAt.addingTimeInterval(61) }
        )
        let service = makeService(store: staleStore)

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected stale capability state to deny session admission")
        } catch let error as ComputerUseService.ServiceError {
            guard case .capabilityStateUnavailable = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testFreshPublishCannotRenewOldBudgetAuthority() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(now: now)
        do {
            _ = try await store.update(
                makeState(
                    revision: 1,
                    generatedAt: now,
                    authorityObservedAt: now,
                    budgetUpdatedAt: now.addingTimeInterval(
                        -ComputerUseCapabilityFreshness.maximumBudgetUpdateAge - 1
                    )
                )
            )
            XCTFail("Expected old upstream budget authority to fail despite a fresh publish")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .stale)
        }
    }

    func testFreshPublishCannotRenewProlongedOfflineAuthority() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(now: now)
        do {
            _ = try await store.update(
                makeState(
                    revision: 1,
                    generatedAt: now,
                    authorityObservedAt: now.addingTimeInterval(
                        -ComputerUseCapabilityFreshness.maximumSourceObservationAge - 1
                    ),
                    budgetUpdatedAt: now
                )
            )
            XCTFail("Expected offline source observations to expire")
        } catch let error as ComputerUseCapabilityStateError {
            XCTAssertEqual(error, .stale)
        }
    }

    func testIncompleteOfflinePublicationTerminatesActiveSession() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(now: now)
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 1, generatedAt: now)
            )
        )
        _ = try await service.startSession(startRequest())

        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(
                    revision: 2,
                    generatedAt: now.addingTimeInterval(1),
                    authorityObservedAt: now.addingTimeInterval(
                        -ComputerUseCapabilityFreshness.maximumSourceObservationAge - 1
                    ),
                    budgetUpdatedAt: now,
                    isComplete: false
                )
            )
        )

        let active = await service.hasActiveSession()
        XCTAssertFalse(active)
    }

    func testKillSwitchUpdateTerminatesActiveSession() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(state: makeState(revision: 1))
        )
        _ = try await service.startSession(startRequest())
        let activeBeforeKill = await service.hasActiveSession()
        XCTAssertTrue(activeBeforeKill)

        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 2, killSwitch: true)
            )
        )
        let activeAfterKill = await service.hasActiveSession()
        XCTAssertFalse(activeAfterKill)
    }

    func testEntitlementRevocationTerminatesActiveSession() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(state: makeState(revision: 1))
        )
        _ = try await service.startSession(startRequest())

        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 2, entitlementActive: false)
            )
        )
        let activeAfterRevocation = await service.hasActiveSession()
        XCTAssertFalse(activeAfterRevocation)
    }

    func testAuthorizationRevocationTerminatesActiveSession() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(state: makeState(revision: 1))
        )
        _ = try await service.startSession(startRequest())

        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 2, authorizationRevoked: true)
            )
        )

        let activeAfterRevocation = await service.hasActiveSession()
        XCTAssertFalse(activeAfterRevocation)
    }

    func testExceededDailyQuotaDeniesSessionAdmission() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 1, actionsExecuted: 200)
            )
        )

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected daily quota denial")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .capabilityDenied(ComputerUseDenyReason.dailyLimit.rawValue))
        }
    }

    func testPhoneControlActionsDoNotConsumeHostedActionCap() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 1, actionsExecuted: 200, phoneControlIntentsExecuted: 200)
            )
        )

        _ = try await service.startSession(startRequest())
        let hasActiveSession = await service.hasActiveSession()
        XCTAssertTrue(hasActiveSession)
    }

    func testUnrelatedEntitlementProductDeniesSessionAdmission() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 1, entitlementProductID: "com.example.unrelated")
            )
        )

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected unrelated entitlement product to deny session admission")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .capabilityDenied(ComputerUseDenyReason.entitlement.rawValue))
        }
    }

    func testExternalConcurrentSessionDeniesSessionAdmission() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 1, concurrentSessionActive: true)
            )
        )

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected concurrent-session denial")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue))
        }
    }

    func testDailySessionQuotaUpdateTerminatesActiveSession() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(state: makeState(revision: 1))
        )
        _ = try await service.startSession(startRequest())

        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 2, sessionsStarted: 4)
            )
        )
        let activeAfterLimit = await service.hasActiveSession()
        XCTAssertFalse(activeAfterLimit)
    }

    func testDailySpendQuotaDeniesSessionAdmission() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(
                state: makeState(revision: 1, visionModelSpendUSD: 5)
            )
        )

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected daily spend ceiling denial")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .capabilityDenied(ComputerUseDenyReason.dailySpendCeiling.rawValue))
        }
    }

    func testConcurrentSessionStartsReserveAtomicallyAndAdmitExactlyOne() async throws {
        let store = makeStore()
        let factoryBarrier = CapabilitySuspensionBarrier()
        let service = makeService(
            store: store,
            playwrightDriverFactory: { _ in
                await factoryBarrier.suspend()
                return nil
            }
        )
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(state: makeState(revision: 1))
        )

        let request = startRequest()
        let winningStart = Task { try await service.startSession(request) }
        await factoryBarrier.waitUntilSuspended()

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("A concurrent start must lose the atomic reservation")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue))
        }

        await factoryBarrier.release()
        _ = try await winningStart.value
        let hasActiveSession = await service.hasActiveSession()
        XCTAssertTrue(hasActiveSession)
    }

    func testFailedSessionFactoryReleasesStartReservation() async throws {
        let store = makeStore()
        let attempts = OpenBurnBarCore.Locked(0)
        let service = makeService(
            store: store,
            playwrightDriverFactory: { _ in
                let attempt = attempts.withLock { value -> Int in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    throw NSError(domain: "ComputerUseStartTests", code: 1)
                }
                return nil
            }
        )
        _ = try await service.updateCapabilityState(
            ComputerUseCapabilityStateUpdateRequest(state: makeState(revision: 1))
        )

        do {
            _ = try await service.startSession(startRequest())
            XCTFail("Expected the first driver factory call to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ComputerUseStartTests")
        }

        _ = try await service.startSession(startRequest())
        XCTAssertEqual(attempts.read(), 2)
        let hasActiveSession = await service.hasActiveSession()
        XCTAssertTrue(hasActiveSession)
    }

    private func makeService(
        store: ComputerUseCapabilityStateStore,
        playwrightDriverFactory: @escaping @Sendable (
            ComputerUseSessionManifest
        ) async throws -> OpenBurnBarPlaywrightDriver? = { _ in nil }
    ) -> ComputerUseService {
        ComputerUseService(
            auditBaseDirectory: temporaryDirectory(),
            capabilityStateStore: store,
            leafKillSwitch: { false },
            playwrightDriverFactory: playwrightDriverFactory
        )
    }

    private func makeStore(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        maximumAge: TimeInterval = 120
    ) -> ComputerUseCapabilityStateStore {
        ComputerUseCapabilityStateStore(
            fileURL: temporaryDirectory().appendingPathComponent("capability-state.json"),
            maximumAge: maximumAge,
            now: { now }
        )
    }

    private func makeState(
        revision: UInt64,
        generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        entitlementActive: Bool = true,
        actionsExecuted: Int = 0,
        phoneControlIntentsExecuted: Int = 0,
        sessionsStarted: Int = 0,
        visionModelSpendUSD: Double = 0,
        concurrentSessionActive: Bool = false,
        killSwitch: Bool = false,
        authorizationRevoked: Bool = false,
        quotaDayKey: String = "2027-01-15",
        entitlementProductID: String = "com.openburnbar.hostedComputerUseSync.monthly",
        authorityObservedAt: Date? = nil,
        budgetUpdatedAt: Date? = nil,
        isComplete: Bool = true
    ) -> ComputerUseCapabilityStateSnapshot {
        let observedAt = authorityObservedAt ?? generatedAt
        let budgetUpdatedAt = budgetUpdatedAt ?? generatedAt
        return ComputerUseCapabilityStateSnapshot(
            publisherInstanceID: "test-publisher",
            revision: revision,
            generatedAt: generatedAt,
            userID: "test-user",
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: entitlementActive,
                productId: entitlementProductID,
                expireAt: generatedAt.addingTimeInterval(3_600),
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: true,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            entitlementProvenance: ComputerUseAuthorityProvenance(
                source: .firestoreServer,
                observedAt: observedAt,
                updatedAt: generatedAt
            ),
            budgetEnvelope: ComputerUseBudgetEnvelope(
                level: .normal,
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                activeActionsPerRun: 50,
                activeActionsPerDay: 200,
                activeSessionsPerDay: 4,
                perUserDailySpendCeilingUSD: 5,
                updatedAt: budgetUpdatedAt
            ),
            budgetProvenance: ComputerUseAuthorityProvenance(
                source: .firestoreServer,
                observedAt: observedAt,
                updatedAt: budgetUpdatedAt
            ),
            quotaUsage: ComputerUseQuotaUsage(
                dayKey: quotaDayKey,
                browserActionsExecuted: actionsExecuted,
                phoneControlIntentsExecuted: phoneControlIntentsExecuted,
                sessionsStarted: sessionsStarted,
                visionModelSpendUSD: visionModelSpendUSD,
                updatedAt: generatedAt
            ),
            quotaProvenance: ComputerUseAuthorityProvenance(
                source: .firestoreServer,
                observedAt: observedAt,
                updatedAt: generatedAt
            ),
            concurrentSessionActive: concurrentSessionActive,
            killSwitch: killSwitch,
            authorizationRevoked: authorizationRevoked,
            isComplete: isComplete
        )
    }

    private func startRequest() -> ComputerUseSessionStartRequest {
        ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "test-client")
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-capability-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor CapabilitySuspensionBarrier {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
