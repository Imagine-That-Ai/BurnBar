plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.21" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
    id("org.jetbrains.kotlin.kapt") version "2.2.21" apply false
    // ktlint: Kotlin code style enforcement + formatter
    // 12.3.0 = last stable 12.x; fixes pre-commit hook binary-file and
    // configuration-cache bugs. Compatible with Gradle 8.9 + Kotlin 2.2.x + AGP 8.7.3.
    id("org.jlleitschuh.gradle.ktlint") version "12.3.0" apply false
    // detekt: Kotlin static analysis — dead code, complexity, naming, style
    id("io.gitlab.arturbosch.detekt") version "1.23.7" apply false
    // dependency-analysis: detect unused Android Gradle dependencies
    id("com.autonomousapps.dependency-analysis") version "2.19.0" apply false
    // Macrobenchmark + baseline-profile capture (:macrobenchmark, on-device only).
    // benchmark 1.3.4 is the latest 1.3.x line, compatible with AGP 8.7.3 + Gradle 8.9.
    id("com.android.test") version "8.7.3" apply false
    id("androidx.baselineprofile") version "1.3.4" apply false
}
