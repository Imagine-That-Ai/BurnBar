plugins {
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.21" apply false
    id("com.google.gms.google-services") version "4.4.4" apply false
    id("com.google.firebase.crashlytics") version "3.0.7" apply false
    id("com.android.legacy-kapt") version "9.2.1" apply false
    // ktlint: Kotlin code style enforcement + formatter
    // 12.3.0 = last stable 12.x; fixes pre-commit hook binary-file and
    // configuration-cache bugs. Compatible with Kotlin 2.2.x and Gradle 9.x.
    id("org.jlleitschuh.gradle.ktlint") version "12.3.0" apply false
    // detekt: Kotlin static analysis — dead code, complexity, naming, style
    id("dev.detekt") version "2.0.0-alpha.3" apply false
    // dependency-analysis: detect unused Android Gradle dependencies
    id("com.autonomousapps.dependency-analysis") version "2.19.0" apply false
    // Macrobenchmark + baseline-profile capture (:macrobenchmark, on-device only).
    // 1.5.0-alpha06 is the first line with AGP 9 new-DSL support.
    id("com.android.test") version "9.2.1" apply false
    id("androidx.baselineprofile") version "1.5.0-alpha06" apply false
}
