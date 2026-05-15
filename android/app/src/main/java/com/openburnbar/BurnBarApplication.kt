package com.openburnbar

import android.app.Application
import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.AppCheckProviderFactory
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.appcheck.playintegrity.PlayIntegrityAppCheckProviderFactory
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.data.widget.BurnBarWidgetSyncWorker

class BurnBarApplication : Application() {
    companion object {
        lateinit var appContext: Context
            private set
    }

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        FirebaseApp.initializeApp(this)
        installAppCheckProvider()
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)
        // Widget snapshot: hydrate from disk + schedule the 15-min refresh.
        BurnBarWidgetSnapshotStore.bind(this)
        BurnBarWidgetSyncWorker.enqueuePeriodic(this)
    }

    /**
     * Three-way provider selection — chosen so App Check enforcement on
     * the server can stay ON in every distribution channel:
     *
     * 1. **Debug builds** (`BuildConfig.DEBUG`): use the Firebase Debug
     *    provider. On first launch the SDK logs a debug secret; that
     *    secret must be registered in the Firebase Console → App Check →
     *    "Manage debug tokens" list (one entry per developer device).
     *
     * 2. **Release builds destined for Firebase App Distribution**
     *    (`BuildConfig.USE_DEBUG_APP_CHECK == true`): use the Debug
     *    provider but pre-seed its SharedPreferences with the fixed
     *    `BuildConfig.APP_CHECK_DEBUG_TOKEN`. The same token is
     *    pre-registered server-side, so every install of this APK passes
     *    App Check without exposing real Play Integrity attestation —
     *    necessary because Play Integrity rejects APKs that have never
     *    been uploaded to Play Console.
     *
     * 3. **Release builds destined for Play Store**
     *    (default — both flags unset): use PlayIntegrity. Real users get
     *    real attestation, and the debug token is never on this APK.
     *
     * Server-side enforcement remains ENFORCED in every case.
     */
    private fun installAppCheckProvider() {
        val factory: AppCheckProviderFactory = when {
            BuildConfig.DEBUG -> {
                seedDebugAppCheckTokenIfNeeded(this, BuildConfig.APP_CHECK_DEBUG_TOKEN)
                Log.i("BurnBar", "AppCheck: using Debug provider (debug build)")
                debugAppCheckProviderFactory()
            }
            BuildConfig.USE_DEBUG_APP_CHECK -> {
                seedDebugAppCheckTokenIfNeeded(this, BuildConfig.APP_CHECK_DEBUG_TOKEN)
                Log.i("BurnBar", "AppCheck: using Debug provider (App Distribution build, seeded token)")
                debugAppCheckProviderFactory()
            }
            else -> {
                Log.i("BurnBar", "AppCheck: using Play Integrity (production)")
                PlayIntegrityAppCheckProviderFactory.getInstance()
            }
        }
        FirebaseAppCheck.getInstance().installAppCheckProviderFactory(factory)
    }

    private fun debugAppCheckProviderFactory(): AppCheckProviderFactory {
        val factoryClass = Class.forName("com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory")
        return factoryClass.getMethod("getInstance").invoke(null) as AppCheckProviderFactory
    }

    /**
     * Seed Firebase's Debug provider SharedPreferences with a pre-registered
     * debug secret so every instance of this APK presents the same token to
     * the App Check exchange endpoint. The SDK stores its secret under
     *
     *   prefs  : "com.google.firebase.appcheck.debug.store.{persistenceKey}"
     *   key    : "com.google.firebase.appcheck.debug.DEBUG_SECRET"
     *
     * (extracted from `StorageHelper` in firebase-appcheck-debug 18.x —
     * file `com/google/firebase/appcheck/debug/internal/StorageHelper.java`)
     */
    private fun seedDebugAppCheckTokenIfNeeded(context: Context, token: String) {
        if (token.isBlank()) {
            Log.w("BurnBar", "USE_DEBUG_APP_CHECK is true but no APP_CHECK_DEBUG_TOKEN set — token will be auto-generated and printed to logcat.")
            return
        }
        val persistenceKey = FirebaseApp.getInstance().persistenceKey
        val prefsName = "com.google.firebase.appcheck.debug.store.$persistenceKey"
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val existing = prefs.getString("com.google.firebase.appcheck.debug.DEBUG_SECRET", null)
        if (existing != token) {
            prefs.edit().putString("com.google.firebase.appcheck.debug.DEBUG_SECRET", token).apply()
        }
    }
}
