package com.openburnbar

import android.app.Application
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.AppCheckProviderFactory
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.appcheck.playintegrity.PlayIntegrityAppCheckProviderFactory
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.openburnbar.menubar.MenuBarService

class BurnBarApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FirebaseApp.initializeApp(this)
        installAppCheckProvider()
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)
        // Notification channel must exist before the service tries to post.
        MenuBarService.ensureChannel(this)
    }

    private fun installAppCheckProvider() {
        val providerFactory = if (BuildConfig.DEBUG) {
            debugAppCheckProviderFactory()
        } else {
            PlayIntegrityAppCheckProviderFactory.getInstance()
        }
        FirebaseAppCheck.getInstance().installAppCheckProviderFactory(providerFactory)
    }

    private fun debugAppCheckProviderFactory(): AppCheckProviderFactory {
        val factoryClass = Class.forName("com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory")
        return factoryClass.getMethod("getInstance").invoke(null) as AppCheckProviderFactory
    }
}
