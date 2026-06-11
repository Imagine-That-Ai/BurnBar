package com.openburnbar.macrobenchmark

import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until

internal const val TARGET_PACKAGE = "com.openburnbar"

private const val LAUNCH_SETTLE_TIMEOUT_MILLIS = 10_000L
private const val TAB_FIND_TIMEOUT_MILLIS = 3_000L
private const val TAB_SETTLE_TIMEOUT_MILLIS = 2_000L

/**
 * Cold-start + first-content wait shared by the startup benchmark and the
 * profile generator. `startActivityAndWait` returns at first frame; waiting
 * for idle lets the Pulse skeleton → content transition (or the login
 * screen) settle so profiles capture the real startup hot paths.
 */
internal fun MacrobenchmarkScope.startAndSettle() {
    pressHome()
    startActivityAndWait()
    device.waitForIdle(LAUNCH_SETTLE_TIMEOUT_MILLIS)
}

/**
 * Drives the Pulse → Burn → Assistants → Pulse journey through the bottom
 * tray, matching tabs by their visible labels. Every step is best-effort:
 * a signed-out device sits on the login screen with no tray, and the
 * journey silently degrades to a startup-only capture (still the largest
 * win — sign the device in before generating for full journey coverage).
 */
internal fun MacrobenchmarkScope.drivePrimaryTabJourney() {
    device.tapTabIfPresent("Burn")
    device.tapTabIfPresent("Assistants")
    device.tapTabIfPresent("Pulse")
}

private fun UiDevice.tapTabIfPresent(label: String) {
    val tab =
        wait(Until.findObject(By.text(label).clickable(true)), TAB_FIND_TIMEOUT_MILLIS)
            ?: wait(Until.findObject(By.text(label)), TAB_FIND_TIMEOUT_MILLIS)
            ?: wait(Until.findObject(By.desc(label)), TAB_FIND_TIMEOUT_MILLIS)
            ?: return
    tab.click()
    waitForIdle(TAB_SETTLE_TIMEOUT_MILLIS)
}
