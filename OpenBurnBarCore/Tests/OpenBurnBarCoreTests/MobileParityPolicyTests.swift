import XCTest
@testable import OpenBurnBarCore

final class MobileParityPolicyTests: XCTestCase {
    func testFirebaseUnavailableIsNotSignedOut() {
        XCTAssertNotEqual(
            MobileAuthSessionPolicy.stateWhenFirebaseUnavailable(),
            .signedOut
        )
        XCTAssertEqual(
            MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable: false),
            .firebaseUnavailable
        )
        XCTAssertEqual(
            MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable: true),
            .signedOut
        )
        XCTAssertFalse(MobileAuthSessionState.firebaseUnavailable.isSignedIn)
        XCTAssertFalse(MobileAuthSessionState.signedOut.isSignedIn)
        XCTAssertTrue(MobileAuthSessionState.signedIn.isSignedIn)
        XCTAssertTrue(MobileAuthSessionState.deletingAccount.isSignedIn)
    }

    func testAppCheckIsDistinctFromPermissionDenied() {
        XCTAssertEqual(
            MobileAuthSessionPolicy.classify(code: "app-check-failed", message: "Firebase App Check token is invalid."),
            .appCheck
        )
        XCTAssertEqual(
            MobileAuthSessionPolicy.classify(code: "permission-denied", message: "Missing or insufficient permissions."),
            .permissionDenied
        )
        XCTAssertNotEqual(
            MobileAuthErrorClass.appCheck.userVisibleLabel,
            MobileAuthErrorClass.permissionDenied.userVisibleLabel
        )
    }

    func testRevokedAndExpiredAreDistinct() {
        XCTAssertEqual(MobileAuthSessionPolicy.classify(code: "user-disabled"), .revokedAccount)
        XCTAssertEqual(MobileAuthSessionPolicy.classify(code: "id-token-expired"), .expired)
        XCTAssertEqual(MobileAuthSessionPolicy.classify(code: "account-switch"), .accountSwitch)
        XCTAssertEqual(MobileAuthSessionPolicy.classify(code: "unavailable"), .network)
        XCTAssertEqual(MobileAuthSessionPolicy.classify(code: "invalid-argument"), .malformed)
    }

    func testAccountSwitchDoesNotServePreviousUid() {
        let previous = MobileAuthSessionEpoch(uid: "uid-a", generation: 3)
        let next = previous.advanced(for: "uid-b")
        XCTAssertTrue(MobileAuthSessionPolicy.shouldReconcile(previousUid: "uid-a", nextUid: "uid-b"))
        XCTAssertFalse(MobileAuthSessionPolicy.shouldReconcile(previousUid: "uid-a", nextUid: "uid-a"))
        XCTAssertFalse(MobileAuthSessionPolicy.isCurrent(expected: previous, current: next))
        XCTAssertFalse(
            MobileAuthSessionPolicy.shouldServeCachedData(
                cacheUid: "uid-a",
                activeUid: "uid-b",
                cacheGeneration: 3,
                activeGeneration: 4
            )
        )
        XCTAssertTrue(
            MobileAuthSessionPolicy.shouldServeCachedData(
                cacheUid: "uid-b",
                activeUid: "uid-b",
                cacheGeneration: 4,
                activeGeneration: 4
            )
        )
    }

    func testSignOutClearsUidScopedCacheEligibility() {
        XCTAssertFalse(
            MobileAuthSessionPolicy.shouldServeCachedData(
                cacheUid: "uid-a",
                activeUid: nil,
                cacheGeneration: 1,
                activeGeneration: 2
            )
        )
    }

    func testSyncFreshnessNeverLooksLikeLiveZero() {
        XCTAssertEqual(
            MobileSyncOwnershipPolicy.freshness(hasData: false, failed: false, offline: false, stale: false, partial: false),
            .empty
        )
        XCTAssertEqual(
            MobileSyncOwnershipPolicy.freshness(hasData: false, failed: true, offline: false, stale: false, partial: false),
            .failed
        )
        XCTAssertEqual(
            MobileSyncOwnershipPolicy.freshness(hasData: true, failed: false, offline: true, stale: false, partial: false),
            .offline
        )
        XCTAssertEqual(
            MobileSyncOwnershipPolicy.freshness(hasData: true, failed: false, offline: false, stale: true, partial: false),
            .stale
        )
        XCTAssertEqual(
            MobileSyncOwnershipPolicy.freshness(hasData: true, failed: false, offline: false, stale: false, partial: true),
            .partial
        )
        XCTAssertEqual(
            MobileSyncOwnershipPolicy.freshness(hasData: true, failed: false, offline: false, stale: false, partial: false),
            .live
        )
        XCTAssertFalse(MobileSyncFreshness.empty.looksLikeLiveZero)
        XCTAssertFalse(MobileSyncFreshness.failed.looksLikeLiveZero)
        XCTAssertFalse(MobileSyncFreshness.offline.looksLikeLiveZero)
        XCTAssertTrue(MobileSyncFreshness.live.looksLikeLiveZero)
        XCTAssertNotEqual(MobileSyncFreshness.empty, MobileSyncFreshness.failed)
        XCTAssertEqual(MobileSyncOwnershipPolicy.mobileRole, .mobileMirrorsReadOnly)
        XCTAssertFalse(MobileSyncOwnershipPolicy.mobileMayPublishUsage)
    }

    func testCanceledRefreshDoesNotApplyLateResult() {
        let started = 4
        let currentAfterCancel = MobileSyncOwnershipPolicy.nextGeneration(started)
        XCTAssertFalse(
            MobileSyncOwnershipPolicy.shouldApply(
                startedGeneration: started,
                currentGeneration: currentAfterCancel,
                cancelled: false
            )
        )
        XCTAssertFalse(
            MobileSyncOwnershipPolicy.shouldApply(
                startedGeneration: started,
                currentGeneration: started,
                cancelled: true
            )
        )
        XCTAssertTrue(
            MobileSyncOwnershipPolicy.shouldApply(
                startedGeneration: started,
                currentGeneration: started,
                cancelled: false
            )
        )
    }

    func testLocalOnlyAccountIsNotCloudConnected() {
        XCTAssertEqual(MobileProviderAccountPolicy.connectivity(storageScope: "local_only"), .localOnly)
        XCTAssertEqual(MobileProviderAccountPolicy.connectivity(storageScope: "device_keychain"), .localOnly)
        XCTAssertEqual(MobileProviderAccountPolicy.connectivity(storageScope: "cloud_refreshable"), .cloudConnected)
        XCTAssertFalse(MobileProviderAccountPolicy.isCloudConnected(storageScope: "local_only"))
        XCTAssertEqual(MobileProviderAccountPolicy.classifyError(code: "permission-denied"), .denied)
        XCTAssertEqual(MobileProviderAccountPolicy.classifyError(code: "unavailable"), .offline)
        XCTAssertEqual(MobileProviderAccountPolicy.classifyError(code: "expired"), .expired)
        XCTAssertEqual(MobileProviderAccountPolicy.classifyError(code: "invalid-argument"), .malformed)
    }

    func testEscrowImportFailsClosed() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-b",
                currentDeviceId: "phone-a",
                grantStatus: "granted",
                grantExpiresAtMs: now + 1,
                nowMs: now,
                hasPrivateKey: true,
                envelopeWellFormed: true
            ),
            .wrongDevice
        )
        XCTAssertEqual(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-a",
                currentDeviceId: "phone-a",
                grantStatus: "granted",
                grantExpiresAtMs: now - 1,
                nowMs: now,
                hasPrivateKey: true,
                envelopeWellFormed: true
            ),
            .expiredGrant
        )
        XCTAssertEqual(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-a",
                currentDeviceId: "phone-a",
                grantStatus: "revoked",
                grantExpiresAtMs: now + 1,
                nowMs: now,
                hasPrivateKey: true,
                envelopeWellFormed: true
            ),
            .revokedGrant
        )
        XCTAssertEqual(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-a",
                currentDeviceId: "phone-a",
                grantStatus: "granted",
                grantExpiresAtMs: now + 1,
                nowMs: now,
                hasPrivateKey: false,
                envelopeWellFormed: true
            ),
            .missingKey
        )
        XCTAssertEqual(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-a",
                currentDeviceId: "phone-a",
                grantStatus: "granted",
                grantExpiresAtMs: now + 1,
                nowMs: now,
                hasPrivateKey: true,
                envelopeWellFormed: false
            ),
            .malformedEnvelope
        )
        XCTAssertEqual(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-a",
                currentDeviceId: "phone-a",
                grantStatus: "granted",
                grantExpiresAtMs: nil,
                nowMs: now,
                hasPrivateKey: true,
                envelopeWellFormed: true
            ),
            .expiredGrant
        )
        XCTAssertNil(
            MobileEscrowEnvelopePolicy.classify(
                targetDeviceId: "phone-a",
                currentDeviceId: "phone-a",
                grantStatus: "granted",
                grantExpiresAtMs: now + 1,
                nowMs: now,
                hasPrivateKey: true,
                envelopeWellFormed: true
            )
        )
    }

    func testStoreProductIdsAlignAndPricesAreNotHardcoded() {
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.role(for: MobileStoreEntitlementPolicy.appleCloudMonthly),
            MobileStoreEntitlementPolicy.role(for: MobileStoreEntitlementPolicy.playCloudMonthly)
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.role(for: MobileStoreEntitlementPolicy.appleProMonthly),
            MobileStoreEntitlementPolicy.role(for: MobileStoreEntitlementPolicy.playProMonthly)
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.role(for: MobileStoreEntitlementPolicy.appleUltraAnnual),
            MobileStoreEntitlementPolicy.role(for: MobileStoreEntitlementPolicy.playUltraAnnual)
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.displayPrice(livePrice: "$7.99"),
            .live("$7.99")
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.displayPrice(livePrice: nil).customerFacingText,
            MobileStoreEntitlementPolicy.unavailablePriceLabel
        )
        XCTAssertFalse(MobileStoreEntitlementPolicy.displayPrice(livePrice: "").isLivePrice)
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.classify(
                catalogPresent: false,
                restoring: false,
                revoked: false,
                refunded: false,
                expired: false,
                active: false
            ),
            .missingCatalog
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.classify(
                catalogPresent: true,
                restoring: true,
                revoked: false,
                refunded: false,
                expired: false,
                active: false
            ),
            .restorePending
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.classify(
                catalogPresent: true,
                restoring: false,
                revoked: true,
                refunded: false,
                expired: false,
                active: true
            ),
            .revoked
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.classify(
                catalogPresent: true,
                restoring: false,
                revoked: false,
                refunded: true,
                expired: false,
                active: true
            ),
            .refunded
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.classify(
                catalogPresent: true,
                restoring: false,
                revoked: false,
                refunded: false,
                expired: true,
                active: false
            ),
            .expired
        )
        XCTAssertEqual(
            MobileStoreEntitlementPolicy.classify(
                catalogPresent: true,
                restoring: false,
                revoked: false,
                refunded: false,
                expired: false,
                active: true
            ),
            .active
        )
    }
}
