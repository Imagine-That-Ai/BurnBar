// Macrobenchmark + baseline-profile producer module (android-015).
//
// This module exists so the on-device baseline-profile capture is a
// one-command handoff:
//
//   ./gradlew :app:generateBaselineProfile          # writes app/src/<variant>/generated/baselineProfiles/
//   ./gradlew :macrobenchmark:connectedBenchmarkReleaseAndroidTest  # StartupBenchmark before/after numbers
//
// Both commands need a connected device (API 28+; profile generation prefers
// a rooted device/emulator or API 33+). Nothing in here runs during normal
// app builds, unit tests, or CI lint gates.
//
// Context: androidx.profileinstaller is already on the app's runtime
// classpath transitively (via androidx.activity), so library-shipped Compose
// profiles are installed today — the gap this module closes is an
// APP-SPECIFIC profile covering BurnBar's own startup + Pulse→Burn→Assistants
// journey, which library profiles never cover. Expected gains must be
// measured with StartupBenchmark, not assumed.
plugins {
    id("com.android.test")
    id("androidx.baselineprofile")
}

android {
    namespace = "com.openburnbar.macrobenchmark"
    compileSdk = 35

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    defaultConfig {
        // Macrobenchmark requires 23+; baseline-profile capture requires 28+.
        minSdk = 28
        targetSdk = 35
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    targetProjectPath = ":app"
}

baselineProfile {
    // Capture on whatever device/emulator is attached — keeps the run a
    // one-command handoff without requiring a Gradle-managed device setup.
    useConnectedDevices = true
}

dependencies {
    implementation("androidx.test.ext:junit:1.2.1")
    implementation("androidx.test.uiautomator:uiautomator:2.4.0-beta02")
    implementation("androidx.benchmark:benchmark-macro-junit4:1.5.0-alpha06")
}
