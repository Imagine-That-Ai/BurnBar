import org.gradle.api.artifacts.dsl.LockMode

plugins {
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.21" apply false
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.firebase.crashlytics") version "3.0.7" apply false
    id("com.android.legacy-kapt") version "9.2.1" apply false
    // ktlint: Kotlin code style enforcement + formatter
    // 12.3.0 = last stable 12.x; fixes pre-commit hook binary-file and
    // configuration-cache bugs. Compatible with Kotlin 2.2.x and Gradle 9.x.
    id("org.jlleitschuh.gradle.ktlint") version "12.3.0" apply false
    // Kotlin static analysis: dead code, complexity, naming, style.
    id("dev.detekt") version "2.0.0-alpha.5" apply false
    // dependency-analysis: detect unused Android Gradle dependencies
    id("com.autonomousapps.dependency-analysis") version "3.17.0" apply false
    // Macrobenchmark + baseline-profile capture (:macrobenchmark, on-device only).
    // 1.5.0-alpha06 is the first line with AGP 9 new-DSL support.
    id("com.android.test") version "9.2.1" apply false
    id("androidx.baselineprofile") version "1.5.0-beta01" apply false
}

val openBurnBarCompileSdk =
    providers.gradleProperty("openburnbar.android.compileSdk").map(String::toInt).get()
val openBurnBarTargetSdk =
    providers.gradleProperty("openburnbar.android.targetSdk").map(String::toInt).get()
require(openBurnBarCompileSdk > 0 && openBurnBarTargetSdk in 1..openBurnBarCompileSdk) {
    "OpenBurnBar Android SDK policy must use positive targetSdk <= compileSdk"
}

// Supply-chain hardening (R-S5): activate Gradle dependency locking for every
// module (root + :app + :openburnbar-iroh-relay + :burnbar-remote + :macrobenchmark).
//
// `LockMode.DEFAULT` keeps this a no-op until lock state exists: with no
// `gradle.lockfile` present a configuration resolves exactly as it does today,
// so committing this cannot break the current build. Only `LockMode.STRICT`
// would fail on a missing lockfile — deliberately not used here.
//
// To pin the graph, a maintainer generates the lock state once and commits the
// resulting `gradle.lockfile`s by running any resolving task with --write-locks,
// e.g. per module:
//     ./gradlew :app:dependencies --write-locks
//     ./gradlew :burnbar-remote:dependencies --write-locks
// After the lockfiles land, unexpected (transitive) version drift fails
// resolution instead of silently upgrading — the hole R-S5 targets. Pairs with
// the `distributionSha256Sum` wrapper pin so both the build tool and the
// dependency graph are verified. (Full checksum/signature verification via
// gradle/verification-metadata.xml is intentionally deferred: enabling it
// requires a fully generated trust file or every build fails — a separate,
// higher-risk change.)
allprojects {
    extra["openBurnBarCompileSdk"] = openBurnBarCompileSdk
    extra["openBurnBarTargetSdk"] = openBurnBarTargetSdk
    dependencyLocking {
        lockMode.set(LockMode.DEFAULT)
        lockAllConfigurations()
    }
}
