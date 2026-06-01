package com.openburnbar

import android.content.Intent
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.tasks.await

internal object MainActivityE2EAuth {
    suspend fun ensureSignedIn(intent: Intent, failureMessage: String): String {
        val auth = FirebaseAuth.getInstance()
        val expectedUid = intent.getStringExtra(MainActivity.EXTRA_E2E_FIREBASE_UID)
        if (expectedUid.isNullOrBlank() || auth.currentUser?.uid != expectedUid) {
            val email = intent.getStringExtra(MainActivity.EXTRA_E2E_FIREBASE_EMAIL)?.takeIf { it.isNotBlank() }
            val password = intent.getStringExtra(MainActivity.EXTRA_E2E_FIREBASE_PASSWORD)?.takeIf { it.isNotBlank() }
            if (email == null || password == null) {
                error(failureMessage)
            }
            auth.signInWithEmailAndPassword(email, password).await()
        }
        return auth.currentUser?.uid ?: error(failureMessage)
    }
}
