package com.openburnbar.irohrelay

import android.content.Context
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Installs Android's Application context into the native iroh stack before
 * any endpoint bootstrap. iroh's default DNS resolver reads system DNS through
 * ndk_context on Android; without this, release builds abort below Kotlin.
 */
object OpenBurnBarIrohNativeContext {
    private const val TAG = "OpenBurnBarIroh"
    private val installed = AtomicBoolean(false)

    fun install(context: Context): Boolean {
        if (installed.get()) return true
        return try {
            System.loadLibrary("openburnbar_iroh")
            val ok = installAndroidContext(context.applicationContext)
            if (ok) {
                installed.set(true)
                Log.i(TAG, "Installed Android native context for iroh DNS resolver")
            } else {
                Log.w(TAG, "Unable to install Android native context for iroh DNS resolver")
            }
            ok
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to load Android iroh native context installer", error)
            false
        }
    }

    fun isInstalled(): Boolean = installed.get()

    private external fun installAndroidContext(context: Context): Boolean
}
