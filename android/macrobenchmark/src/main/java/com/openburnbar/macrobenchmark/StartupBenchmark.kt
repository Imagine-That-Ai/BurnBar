package com.openburnbar.macrobenchmark

import androidx.benchmark.macro.BaselineProfileMode
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private const val STARTUP_ITERATIONS = 10

/**
 * Cold-start before/after measurement for the app-specific baseline profile
 * (android-015 capture protocol). Run on a physical device or emulator:
 *
 *   ./gradlew :macrobenchmark:connectedBenchmarkReleaseAndroidTest
 *
 * Compare `timeToInitialDisplayMs` medians between [startupCompilationNone]
 * (worst case: no AOT) and [startupCompilationBaselineProfiles] (the
 * generated profile applied). Only a measured delta may be claimed.
 */
@RunWith(AndroidJUnit4::class)
class StartupBenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun startupCompilationNone() = startup(CompilationMode.None())

    @Test
    fun startupCompilationBaselineProfiles() = startup(CompilationMode.Partial(BaselineProfileMode.Require))

    private fun startup(compilationMode: CompilationMode) = benchmarkRule.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = listOf(StartupTimingMetric()),
        compilationMode = compilationMode,
        startupMode = StartupMode.COLD,
        iterations = STARTUP_ITERATIONS,
    ) {
        startAndSettle()
    }
}
