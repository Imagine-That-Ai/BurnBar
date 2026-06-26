package com.openburnbar.data.computeruse

import android.util.Log
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import com.google.firebase.remoteconfig.remoteConfigSettings

/**
 * F2/F7/F10 — make the protection-flag kill switches actually reachable on
 * Android.
 *
 * The seal protection flags default ON via [remoteConfigProtectionFlag]'s
 * `VALUE_SOURCE_STATIC ⇒ true` rule. Android hardware signing is a separate
 * default-off ramp in [PhoneControlSecureEnclaveKeyPolicy] until a
 * prompt-bound signer exists for every send surface. In both cases, "the
 * operator's Remote Config value wins" is only true if a fetch has actually
 * landed a remote value — and Android never fetched Remote Config at all, so
 * the source stayed permanently `STATIC` and an operator-set value could never
 * reach the device. This bootstrap closes that: it kicks a one-time
 * `fetchAndActivate()` at startup (with a kill-switch-appropriate minimum
 * fetch interval) so a remotely-set value flips `source` to `REMOTE` and the
 * helpers honor it. iOS already does this through
 * `MobileMediaBudgetStatusStore.refreshRemoteConfigKillSwitch()`.
 *
 * Deliberately registers NO in-app defaults: the source-aware helper already
 * supplies the default behavior, so leaving the keys absent keeps `source`
 * at `STATIC` until — and only until — a real remote value arrives. That way
 * an operator who never touches the console gets the intended platform
 * default, and one who sets a value gets an honored ramp/kill switch.
 */
object RemoteConfigBootstrap {
    // / Refresh at most hourly: responsive enough for a security kill switch
    // / without burning Firebase fetch quota. A hard panic also has the
    // / independent per-session `computer_use_kill_switch`.
    private const val MINIMUM_FETCH_INTERVAL_SECONDS = 3_600L

    fun activate() {
        runCatching {
            val remoteConfig = FirebaseRemoteConfig.getInstance()
            remoteConfig.setConfigSettingsAsync(
                remoteConfigSettings {
                    minimumFetchIntervalInSeconds = MINIMUM_FETCH_INTERVAL_SECONDS
                },
            )
            remoteConfig.fetchAndActivate()
                .addOnFailureListener { error ->
                    Log.w(TAG, "remote_config_fetch_failed", error)
                }
        }.onFailure { error ->
            // Firebase not initialized (should not happen post-initializeApp) —
            // safe: the flags stay at their secure static default.
            Log.w(TAG, "remote_config_bootstrap_skipped", error)
        }
    }

    private const val TAG = "RemoteConfigBootstrap"
}
