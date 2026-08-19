package com.openburnbar.data.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileParityPolicyTest {
    @Test
    fun firebaseUnavailableIsNotSignedOut() {
        assertNotEquals(MobileAuthSessionPolicy.stateWhenFirebaseUnavailable(), MobileAuthSessionState.SIGNED_OUT)
        assertEquals(
            MobileAuthSessionState.FIREBASE_UNAVAILABLE,
            MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable = false),
        )
        assertEquals(MobileAuthSessionState.SIGNED_OUT, MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable = true))
        assertFalse(MobileAuthSessionState.FIREBASE_UNAVAILABLE.isSignedIn)
        assertTrue(MobileAuthSessionState.SIGNED_IN.isSignedIn)
    }

    @Test
    fun appCheckIsDistinctFromPermissionDenied() {
        assertEquals(
            MobileAuthErrorClass.APP_CHECK,
            MobileAuthSessionPolicy.classify("app-check-failed", "Firebase App Check token is invalid."),
        )
        assertEquals(
            MobileAuthErrorClass.PERMISSION_DENIED,
            MobileAuthSessionPolicy.classify("permission-denied", "Missing or insufficient permissions."),
        )
        assertNotEquals(
            MobileAuthErrorClass.APP_CHECK.userVisibleLabel,
            MobileAuthErrorClass.PERMISSION_DENIED.userVisibleLabel,
        )
    }

    @Test
    fun accountSwitchDoesNotServePreviousUid() {
        val previous = MobileAuthSessionEpoch("uid-a", 3)
        val next = previous.advanced("uid-b")
        assertTrue(MobileAuthSessionPolicy.shouldReconcile("uid-a", "uid-b"))
        assertFalse(MobileAuthSessionPolicy.isCurrent(previous, next))
        assertFalse(MobileAuthSessionPolicy.shouldServeCachedData("uid-a", "uid-b", 3, 4))
        assertTrue(MobileAuthSessionPolicy.shouldServeCachedData("uid-b", "uid-b", 4, 4))
    }

    @Test
    fun signOutClearsUidScopedCacheEligibility() {
        val caches = UidScopedCacheRegistry()
        var cleared = 0
        caches.register { cleared += 1 }
        caches.clearAll()
        assertEquals(1, cleared)
        assertFalse(MobileAuthSessionPolicy.shouldServeCachedData("uid-a", null, 1, 2))
    }

    @Test
    fun uidScopedCacheUnregisterStopsLaterClears() {
        val caches = UidScopedCacheRegistry()
        var cleared = 0
        val clearer = { cleared += 1 }
        caches.register(clearer)
        caches.unregister(clearer)
        caches.clearAll()
        assertEquals(0, cleared)
    }

    @Test
    fun syncFreshnessNeverLooksLikeLiveZero() {
        assertEquals(
            MobileSyncFreshness.EMPTY,
            MobileSyncOwnershipPolicy.freshness(hasData = false, failed = false, offline = false, stale = false, partial = false),
        )
        assertEquals(
            MobileSyncFreshness.FAILED,
            MobileSyncOwnershipPolicy.freshness(hasData = false, failed = true, offline = false, stale = false, partial = false),
        )
        assertEquals(
            MobileSyncFreshness.OFFLINE,
            MobileSyncOwnershipPolicy.freshness(hasData = true, failed = false, offline = true, stale = false, partial = false),
        )
        assertFalse(MobileSyncFreshness.EMPTY.looksLikeLiveZero)
        assertFalse(MobileSyncFreshness.FAILED.looksLikeLiveZero)
        assertTrue(MobileSyncFreshness.LIVE.looksLikeLiveZero)
        assertFalse(MobileSyncOwnershipPolicy.mobileMayPublishUsage)
        assertEquals(MobileSyncPublisherRole.MOBILE_MIRRORS_READ_ONLY, MobileSyncOwnershipPolicy.mobileRole)
    }

    @Test
    fun canceledRefreshDoesNotApplyLateResult() {
        val started = 4
        val current = MobileSyncOwnershipPolicy.nextGeneration(started)
        assertFalse(MobileSyncOwnershipPolicy.shouldApply(started, current, cancelled = false))
        assertFalse(MobileSyncOwnershipPolicy.shouldApply(started, started, cancelled = true))
        assertTrue(MobileSyncOwnershipPolicy.shouldApply(started, started, cancelled = false))
    }

    @Test
    fun localOnlyAccountIsNotCloudConnected() {
        assertEquals(MobileProviderConnectivity.LOCAL_ONLY, MobileProviderAccountPolicy.connectivity("local_only"))
        assertFalse(MobileProviderAccountPolicy.isCloudConnected("device_keychain"))
        assertTrue(MobileProviderAccountPolicy.isCloudConnected("cloud_refreshable"))
        assertEquals(MobileProviderErrorClass.DENIED, MobileProviderAccountPolicy.classifyError("permission-denied"))
        assertEquals(MobileProviderErrorClass.OFFLINE, MobileProviderAccountPolicy.classifyError("unavailable"))
        assertEquals(MobileProviderErrorClass.EXPIRED, MobileProviderAccountPolicy.classifyError("expired"))
        assertEquals(MobileProviderErrorClass.MALFORMED, MobileProviderAccountPolicy.classifyError("invalid-argument"))
    }

    @Test
    fun escrowImportFailsClosed() {
        val now = 1_700_000_000_000L
        assertEquals(
            MobileEscrowImportFailure.WRONG_DEVICE,
            MobileEscrowEnvelopePolicy.classify("phone-b", "phone-a", "granted", now + 1, now, true, true),
        )
        assertEquals(
            MobileEscrowImportFailure.EXPIRED_GRANT,
            MobileEscrowEnvelopePolicy.classify("phone-a", "phone-a", "granted", now - 1, now, true, true),
        )
        assertEquals(
            MobileEscrowImportFailure.REVOKED_GRANT,
            MobileEscrowEnvelopePolicy.classify("phone-a", "phone-a", "revoked", now + 1, now, true, true),
        )
        assertEquals(
            MobileEscrowImportFailure.MISSING_KEY,
            MobileEscrowEnvelopePolicy.classify("phone-a", "phone-a", "granted", now + 1, now, false, true),
        )
        assertEquals(
            MobileEscrowImportFailure.MALFORMED_ENVELOPE,
            MobileEscrowEnvelopePolicy.classify("phone-a", "phone-a", "granted", now + 1, now, true, false),
        )
        assertNull(MobileEscrowEnvelopePolicy.classify("phone-a", "phone-a", "granted", null, now, true, true))
        assertNull(MobileEscrowEnvelopePolicy.classify("phone-a", "phone-a", "granted", now + 1, now, true, true))
    }

    @Test
    fun storeProductIdsAlignAndPricesAreNotHardcoded() {
        assertEquals(
            MobileStoreEntitlementPolicy.role(MobileStoreEntitlementPolicy.APPLE_CLOUD_MONTHLY),
            MobileStoreEntitlementPolicy.role(MobileStoreEntitlementPolicy.PLAY_CLOUD_MONTHLY),
        )
        assertEquals(
            MobileStoreEntitlementPolicy.role(MobileStoreEntitlementPolicy.APPLE_PRO_MONTHLY),
            MobileStoreEntitlementPolicy.role(MobileStoreEntitlementPolicy.PLAY_PRO_MONTHLY),
        )
        assertEquals(
            MobileStoreEntitlementPolicy.role(MobileStoreEntitlementPolicy.APPLE_ULTRA_ANNUAL),
            MobileStoreEntitlementPolicy.role(MobileStoreEntitlementPolicy.PLAY_ULTRA_ANNUAL),
        )
        assertEquals(MobileStoreProductRole.CLOUD_MONTHLY, MobileStoreEntitlementPolicy.role(HostedQuotaIds.PRODUCT_ID))
        assertTrue(MobileStoreEntitlementPolicy.displayPrice("$7.99").isLivePrice)
        assertEquals(
            MobileStoreEntitlementPolicy.UNAVAILABLE_PRICE_LABEL,
            MobileStoreEntitlementPolicy.displayPrice(null).customerFacingText,
        )
        assertEquals(
            MobileStoreEntitlementState.MISSING_CATALOG,
            MobileStoreEntitlementPolicy.classify(false, false, false, false, false, false),
        )
        assertEquals(
            MobileStoreEntitlementState.RESTORE_PENDING,
            MobileStoreEntitlementPolicy.classify(true, true, false, false, false, false),
        )
        assertEquals(
            MobileStoreEntitlementState.REVOKED,
            MobileStoreEntitlementPolicy.classify(true, false, true, false, false, true),
        )
        assertEquals(
            MobileStoreEntitlementState.REFUNDED,
            MobileStoreEntitlementPolicy.classify(true, false, false, true, false, true),
        )
        assertEquals(
            MobileStoreEntitlementState.EXPIRED,
            MobileStoreEntitlementPolicy.classify(true, false, false, false, true, false),
        )
        assertEquals(
            MobileStoreEntitlementState.ACTIVE,
            MobileStoreEntitlementPolicy.classify(true, false, false, false, false, true),
        )
    }
}

private object HostedQuotaIds {
    const val PRODUCT_ID = "com.openburnbar.pro.monthly"
}
