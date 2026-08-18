package com.openburnbar.data.policy

enum class MobileAuthSessionState(val wire: String) {
    SIGNED_OUT("signed-out"),
    SIGNING_IN("signing-in"),
    SIGNED_IN("signed-in"),
    DELETING_ACCOUNT("deleting-account"),
    FIREBASE_UNAVAILABLE("firebase-unavailable"),
    FIRESTORE_UNAVAILABLE("firestore-unavailable"),
    ;

    val isSignedIn: Boolean
        get() = this == SIGNED_IN || this == DELETING_ACCOUNT
}

enum class MobileAuthErrorClass(val wire: String, val userVisibleLabel: String) {
    NONE("none", ""),
    APP_CHECK("app-check", "App Check blocked"),
    REVOKED_ACCOUNT("revoked-account", "Account revoked"),
    EXPIRED("expired", "Session expired"),
    ACCOUNT_SWITCH("account-switch", "Account mismatch"),
    PERMISSION_DENIED("permission-denied", "Permission denied"),
    FIREBASE_UNAVAILABLE("firebase-unavailable", "Firebase unavailable"),
    FIRESTORE_UNAVAILABLE("firestore-unavailable", "Firestore unavailable"),
    NETWORK("network", "Offline"),
    MALFORMED("malformed", "Could not complete sign-in"),
}

data class MobileAuthSessionEpoch(
    val uid: String?,
    val generation: Int,
) {
    fun advanced(nextUid: String?): MobileAuthSessionEpoch =
        MobileAuthSessionEpoch(uid = nextUid, generation = generation + 1)
}

object MobileAuthSessionPolicy {
    fun shouldReconcile(previousUid: String?, nextUid: String?): Boolean = previousUid != nextUid

    fun isCurrent(
        expectedUid: String?,
        expectedGeneration: Long,
        currentUid: String?,
        currentGeneration: Long,
    ): Boolean = expectedUid == currentUid && expectedGeneration == currentGeneration

    fun isCurrent(expected: MobileAuthSessionEpoch, current: MobileAuthSessionEpoch): Boolean =
        isCurrent(
            expectedUid = expected.uid,
            expectedGeneration = expected.generation.toLong(),
            currentUid = current.uid,
            currentGeneration = current.generation.toLong(),
        )

    fun shouldServeCachedData(
        cacheUid: String?,
        activeUid: String?,
        cacheGeneration: Int,
        activeGeneration: Int,
    ): Boolean {
        if (cacheUid.isNullOrEmpty() || activeUid.isNullOrEmpty() || cacheUid != activeUid) return false
        return cacheGeneration == activeGeneration
    }

    fun stateWhenFirebaseUnavailable(): MobileAuthSessionState = MobileAuthSessionState.FIREBASE_UNAVAILABLE

    fun stateAfterSignOut(firebaseAvailable: Boolean): MobileAuthSessionState =
        if (firebaseAvailable) MobileAuthSessionState.SIGNED_OUT else MobileAuthSessionState.FIREBASE_UNAVAILABLE

    fun classify(code: String, message: String? = null): MobileAuthErrorClass {
        val haystack = listOf(code, message.orEmpty()).joinToString(" ").replace(" ", "").lowercase()
        return when {
            "appcheck" in haystack || "attestation" in haystack -> MobileAuthErrorClass.APP_CHECK
            "user-disabled" in haystack || "userdisabled" in haystack || "revoked" in haystack ->
                MobileAuthErrorClass.REVOKED_ACCOUNT
            "id-token-expired" in haystack || "tokenexpired" in haystack ||
                "sessionexpired" in haystack || "deadline-exceeded" in haystack ->
                MobileAuthErrorClass.EXPIRED
            "accountmismatch" in haystack || "account-switch" in haystack || "uid-changed" in haystack ->
                MobileAuthErrorClass.ACCOUNT_SWITCH
            "permission-denied" in haystack || "permissiondenied" in haystack ||
                "missingorinsufficientpermissions" in haystack ->
                MobileAuthErrorClass.PERMISSION_DENIED
            "firebaseunavailable" in haystack || "firebase-unavailable" in haystack ||
                "configuration_not_found" in haystack ->
                MobileAuthErrorClass.FIREBASE_UNAVAILABLE
            "firestoreunavailable" in haystack || "firestore-unavailable" in haystack ->
                MobileAuthErrorClass.FIRESTORE_UNAVAILABLE
            "unavailable" in haystack || "network" in haystack || "offline" in haystack ->
                MobileAuthErrorClass.NETWORK
            "unauthenticated" in haystack || "notauthenticated" in haystack -> MobileAuthErrorClass.NONE
            else -> MobileAuthErrorClass.MALFORMED
        }
    }
}
