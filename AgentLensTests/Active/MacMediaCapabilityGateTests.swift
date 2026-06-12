import XCTest
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBar

/// Locks in the admission decisions made by `MacMediaCapabilityGate`.
/// This gate is the live admission control surface that Decision 2 of
/// the Mercury master plan calls "Mac is the source of truth", so if a
/// case here regresses, a paying user could either start a session that
/// breaks the budget cap or be wrongly denied during a normal day.
@MainActor
final class MacMediaCapabilityGateTests: XCTestCase {
    private let happyEntitlement = MacMediaCapabilityGate.EntitlementState(
        active: true,
        fileTransfer: true,
        screenShare: true,
        videoCall: true
    )

    private let zeroUsage = MediaQuotaUsageSnapshot()

    private let normalBudget = MediaBudgetStatus(
        level: .normal,
        projectedMonthEndUSD: 200,
        monthToDateUSD: 100,
        lastEvaluatedAt: Date(),
        activeEnvelope: .normal
    )

    func testHappyPathReturnsAllowedForEachFeature() async {
        let gate = makeGate(
            entitlement: happyEntitlement,
            usage: zeroUsage,
            budget: normalBudget,
            concurrent: 0
        )
        for feature in [MediaStreamClass.Feature.fileTransfer, .screenShare, .videoCall] {
            let result = await gate.check(
                feature: feature,
                sessionDurationLimitSeconds: nil,
                sessionByteBudget: nil
            )
            XCTAssertTrue(result.isAllowed, "expected allowed for \(feature)")
        }
    }

    func testEntitlementInactiveDenies() async {
        let entitlement = MacMediaCapabilityGate.EntitlementState(
            active: false, fileTransfer: true, screenShare: true, videoCall: true
        )
        let gate = makeGate(entitlement: entitlement, usage: zeroUsage, budget: normalBudget, concurrent: 0)
        let result = await gate.check(feature: .videoCall, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .entitlementMissing)
    }

    func testSharedMediaEntitlementMappingFailsClosedUntilMediaOrProMaxEntitlementIsActive() {
        let free = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: false, tier: .free)
        XCTAssertFalse(free.active)
        XCTAssertFalse(free.fileTransfer)
        XCTAssertFalse(free.screenShare)
        XCTAssertFalse(free.videoCall)

        let cloudOnly = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: false, tier: .cloud)
        XCTAssertFalse(cloudOnly.active)

        let mediaSKU = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: true, tier: .free)
        XCTAssertTrue(mediaSKU.active)
        XCTAssertTrue(mediaSKU.fileTransfer)
        XCTAssertTrue(mediaSKU.screenShare)
        XCTAssertTrue(mediaSKU.videoCall)

        let proMax = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: false, tier: .pro)
        XCTAssertTrue(proMax.active)
    }

    func testActiveSessionRegistryClampsCountsPerFeature() {
        MacMediaActiveSessionRegistry.shared.resetForTesting()
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .screenShare), 0)

        MacMediaActiveSessionRegistry.shared.setCount(2, for: .screenShare)
        MacMediaActiveSessionRegistry.shared.setCount(1, for: .fileTransfer)
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .screenShare), 2)
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 1)

        MacMediaActiveSessionRegistry.shared.setCount(-10, for: .screenShare)
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .screenShare), 0)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testHardCapDeniesAllFeatures() async {
        let hardCap = MediaBudgetStatus(
            level: .hardCap,
            projectedMonthEndUSD: 1_200,
            monthToDateUSD: 900,
            lastEvaluatedAt: Date(),
            activeEnvelope: .hardCap
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: hardCap, concurrent: 0)
        for feature in [MediaStreamClass.Feature.fileTransfer, .screenShare, .videoCall] {
            let result = await gate.check(feature: feature, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
            guard case .denied(let reason) = result else {
                XCTFail("expected denied for \(feature)")
                return
            }
            XCTAssertEqual(reason, .budgetHardCapReached, "feature \(feature)")
        }
    }

    func testSoftCapEnforcesTightenedEnvelope() async {
        let softCap = MediaBudgetStatus(
            level: .softCap,
            projectedMonthEndUSD: 750,
            monthToDateUSD: 350,
            lastEvaluatedAt: Date(),
            activeEnvelope: .softCap
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: softCap, concurrent: 0)
        // Soft cap still allows screen share but with reduced per-session
        // ceiling; the gate refuses a request that exceeds that ceiling.
        let denied = await gate.check(
            feature: .screenShare,
            sessionDurationLimitSeconds: 60 * 60, // 60 min — exceeds soft cap (30 min)
            sessionByteBudget: nil
        )
        if case .allowed = denied {
            XCTFail("expected denial for over-budget request under soft cap")
        }
    }

    func testConcurrentSessionCeilingDeniesVideoSecondCall() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 1)
        let result = await gate.check(feature: .videoCall, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .concurrentSessionCapReached)
    }

    func testScreenShareAllowsThreeConcurrentMirrorViewers() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 2)
        let result = await gate.check(feature: .screenShare, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        XCTAssertTrue(result.isAllowed)
    }

    func testScreenShareDeniesFourthConcurrentMirrorViewer() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 3)
        let result = await gate.check(feature: .screenShare, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .concurrentSessionCapReached)
    }

    func testPerSessionByteBudgetDenialOnFileTransfer() async {
        let nearCap = MediaQuotaUsageSnapshot(
            bytesUploadedFile: 4_500_000_000, // ~4.5 GB of 5 GB
            bytesDownloadedFile: 0,
            fileTransfersInitiated: 5,
            fileTransfersFailed: 0,
            screenShareSecondsUsed: 0,
            screenShareSessions: 0,
            videoCallSecondsUsed: 0,
            videoCallSessions: 0
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: nearCap, budget: normalBudget, concurrent: 0)
        // A 1 GB upload pushes us past the daily out cap.
        let result = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: 1_000_000_000
        )
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .sessionCapReached)
    }

    func testRemoteUnlockSessionRegistryBindsCredentialSessionToPeer() {
        let service = makeRemoteUnlockReadinessService()
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let session = remoteUnlockSession(
            sessionId: "unlock-session",
            peerNodeId: "ios-peer",
            viewerDeviceId: "iphone-1",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now
            )
        )

        service.recordRemoteUnlockSession(session, now: now)

        XCTAssertTrue(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "android-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "different-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "ipad-1",
                now: now
            )
        )
    }

    func testRemoteUnlockSessionRegistryRejectsExpiredAndRevokedSessions() {
        let service = makeRemoteUnlockReadinessService()
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let session = remoteUnlockSession(
            sessionId: "unlock-session",
            peerNodeId: "ios-peer",
            viewerDeviceId: "iphone-1",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        service.recordRemoteUnlockSession(session, now: now)
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now.addingTimeInterval(61)
            )
        )

        service.recordRemoteUnlockSession(session, now: now)
        service.revokeRemoteUnlockSession(sessionId: "unlock-session")
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now
            )
        )

        service.recordRemoteUnlockSession(session, now: now)
        service.revokeAllRemoteUnlockSessions(revokePublishedTrust: false)
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now
            )
        )
    }

    // MARK: helpers

    private func makeGate(
        entitlement: MacMediaCapabilityGate.EntitlementState,
        usage: MediaQuotaUsageSnapshot,
        budget: MediaBudgetStatus,
        concurrent: Int
    ) -> MacMediaCapabilityGate {
        MacMediaCapabilityGate(
            entitlementProvider: { entitlement },
            usageProvider: { usage },
            budgetProvider: { budget },
            concurrentSessionsProvider: { _ in concurrent }
        )
    }

    private func makeRemoteUnlockReadinessService() -> MacRemoteUnlockReadinessService {
        let defaults = UserDefaults(suiteName: "MacMediaCapabilityGateTests.\(UUID().uuidString)")!
        return MacRemoteUnlockReadinessService(
            defaults: defaults,
            revokesPublishedTrustOnClearAll: false
        )
    }

    private func remoteUnlockSession(
        sessionId: String,
        peerNodeId: String,
        viewerDeviceId: String?,
        requestedAt: Date,
        expiresAt: Date
    ) -> HermesRealtimeRelayRemoteUnlockSession {
        HermesRealtimeRelayRemoteUnlockSession(
            requestId: "unlock-req",
            sessionId: sessionId,
            intent: .request,
            requesterDisplayName: "Alberto's iPhone",
            viewerDeviceId: viewerDeviceId,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            localAuthenticationSatisfied: true,
            requestedLockState: .loginWindow,
            requestedBackend: .appleScreenSharingLoopback,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: peerNodeId,
                counter: 1,
                timestamp: requestedAt,
                intentHashBlake3: "hash",
                signatureEd25519: "signature"
            )
        )
    }
}
