package com.openburnbar.data.hermes

import android.content.Context
import android.content.SharedPreferences

/**
 * One-shot flag that drives the auto-presented Hermes setup wizard the
 * first time the user opens the assistant tab after install.
 */
class HermesOnboardingState(context: Context) {

    private val prefs: SharedPreferences = context
        .applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun shouldAutoPresentSetupWizard(): Boolean {
        if (prefs.getBoolean(KEY_SHOWN, false)) return false
        prefs.edit().putBoolean(KEY_SHOWN, true).apply()
        return true
    }

    fun reset() {
        prefs.edit().remove(KEY_SHOWN).apply()
    }

    companion object {
        private const val PREFS_NAME = "hermes_onboarding"
        private const val KEY_SHOWN = "auto_wizard_shown_v1"
    }
}
