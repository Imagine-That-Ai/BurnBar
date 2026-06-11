package com.openburnbar.macrobenchmark

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Generates the app-specific baseline profile (and startup profile) by
 * driving cold start plus the primary Pulse → Burn → Assistants tab journey.
 *
 * One-command handoff (device attached, API 33+ or rooted 28+; sign the
 * device into the app first so the journey reaches the real tabs instead of
 * the login screen):
 *
 *   ./gradlew :app:generateBaselineProfile
 *
 * The captured rules land under `app/src/<variant>/generated/baselineProfiles/`
 * — commit them so release builds ship the profile and `profileinstaller`
 * installs it on first launch.
 */
@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {
    @get:Rule
    val baselineProfileRule = BaselineProfileRule()

    @Test
    fun generate() = baselineProfileRule.collect(
        packageName = TARGET_PACKAGE,
        includeInStartupProfile = true,
    ) {
        startAndSettle()
        drivePrimaryTabJourney()
    }
}
