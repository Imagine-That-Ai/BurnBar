package com.openburnbar.data.cloud

import com.openburnbar.BurnBarApplication
import com.openburnbar.data.insights.services.AndroidInsightCredentialStore

/** Android analog of iOS Keychain `escrow_{provider}`. */
object AndroidEscrowSecretStore {
    fun persist(provider: String, secret: String): Boolean {
        val cleanProvider = provider.trim()
        val cleanSecret = secret.trim()
        if (cleanProvider.isEmpty() || cleanSecret.isEmpty()) return false
        if (!BurnBarApplication.isAppContextInitialized) return false
        return runCatching {
            val store = AndroidInsightCredentialStore(BurnBarApplication.appContext)
            store.saveCredential(cleanProvider, cleanSecret)
            store.credential(cleanProvider) == cleanSecret
        }.getOrDefault(false)
    }
}
