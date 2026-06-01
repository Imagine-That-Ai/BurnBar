@file:Suppress("MagicNumber")
// E2E proof logging uses literal hash-prefix thresholds for adb log grep.

package com.openburnbar

import android.util.Log
import java.security.MessageDigest

internal object MainActivityE2EComputerUseLogging {
    fun computerUseProofLog(message: String) {
        val line = "AndroidComputerUseE2E $message"
        Log.i(MainActivityE2EConstants.TAG, line)
        val payload = """{"event":"${message.replace("\"", "\\\"")}","timestamp":${System.currentTimeMillis()}}""" + "\n"
        runCatching {
            BurnBarApplication.appContext.openFileOutput("computer-use-e2e-proof.jsonl", android.content.Context.MODE_APPEND).use {
                it.write(payload.toByteArray(Charsets.UTF_8))
            }
        }
    }

    fun swiftDateReferenceSeconds(nowMillis: Long = System.currentTimeMillis()): Double =
        nowMillis.toDouble() / MainActivityE2EConstants.MILLIS_PER_SECOND -
            MainActivityE2EConstants.SWIFT_REFERENCE_EPOCH_OFFSET_SECONDS

    @Suppress("HardwareIds")
    fun androidDeviceIdForComputerUseProof(activity: MainActivity): String {
        val androidId =
            android.provider.Settings.Secure.getString(
                activity.contentResolver,
                android.provider.Settings.Secure.ANDROID_ID,
            ).orEmpty()
        val digest =
            MessageDigest.getInstance("SHA-256")
                .digest(androidId.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
        return "android-$digest"
    }
}
