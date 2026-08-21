import org.gradle.testing.jacoco.tasks.JacocoReport

// Android-library mirror of the Swift OpenBurnBarIrohRelay package.
//
// Same surface, same wire format: HermesRealtimeRelayFrame JSON envelope,
// big-endian u32 length prefix, ALPN `openburnbar/1`, Ed25519 Curve25519
// pairing signatures (verified via Tink because the JDK's
// java.security.Signature("Ed25519") provider is not bundled on every
// Android device until API 31).
//
// This module is consumed by :app via Gradle and ships the generated
// UniFFI Kotlin bindings under uniffi/openburnbar_iroh/ once
// scripts/build-iroh-android-aar.sh has emitted them. Until the AAR
// build runs locally, the bindings directory may be absent — the module
// gracefully degrades to "iroh transport unavailable" at runtime via
// IrohJniBackend.isLoaded(), so :app continues to compile and ship the
// Firestore fallback.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("org.jlleitschuh.gradle.ktlint")
    jacoco
}

android {
    namespace = "com.openburnbar.irohrelay"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        debug {
            enableUnitTestCoverage = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    buildFeatures {
        buildConfig = false
    }

    lint {
        lintConfig = file("lint.xml")
    }

    // The UniFFI-generated Kotlin bindings land under the standard
    // src/main/java/uniffi/openburnbar_iroh/ path from
    // scripts/build-iroh-android-aar.sh.
}

val debugUnitTestCoverageData =
    layout.buildDirectory.file("outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec")
val legacyDebugUnitTestCoverageData =
    layout.buildDirectory.file("jacoco/testDebugUnitTest.exec")
val jacocoClassExcludes =
    listOf(
        "**/R.class",
        "**/R\$*.class",
        "**/BuildConfig.*",
        "**/Manifest*.*",
        "**/*Test*.*",
        "**/*\$Lambda\$*.*",
    )
val debugCoverageClassDirectories =
    files(
        fileTree(layout.buildDirectory.dir("intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes")) {
            exclude(jacocoClassExcludes)
        },
        fileTree(layout.buildDirectory.dir("intermediates/javac/debug/compileDebugJavaWithJavac/classes")) {
            exclude(jacocoClassExcludes)
        },
    )
val debugCoverageSourceDirectories = files("src/main/java", "src/main/kotlin")

tasks.register<JacocoReport>("jacocoTestReport") {
    dependsOn("testDebugUnitTest")
    reports {
        xml.required.set(true)
        html.required.set(true)
        xml.outputLocation.set(
            layout.buildDirectory.file("reports/jacoco/testDebugUnitTest/jacocoTestReport.xml"),
        )
    }
    classDirectories.setFrom(debugCoverageClassDirectories)
    sourceDirectories.setFrom(debugCoverageSourceDirectories)
    executionData.setFrom(debugUnitTestCoverageData)
}

tasks.matching { it.name == "testDebugUnitTest" }.configureEach {
    doFirst {
        debugUnitTestCoverageData.get().asFile.delete()
        legacyDebugUnitTestCoverageData.get().asFile.delete()
    }
    finalizedBy("jacocoTestReport")
}

dependencies {
    // Kotlinx-serialization for the HermesRealtimeRelayFrame JSON wire
    // shape. Same data model the iOS side encodes via JSONEncoder.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // Tink — Ed25519 verifier compatible with iOS Curve25519.Signing on
    // every API level from 26 up. The JDK's java.security.Signature
    // Ed25519 algorithm only landed in API 31+, so Tink is the portable
    // primitive across our minSdk range.
    implementation("com.google.crypto.tink:tink-android:1.23.0")

    // JNA 5.19.0 ships 16 KB page-size aligned native libjnidispatch slices.
    // UniFFI's generated Kotlin bindings use JNA to load the Rust AAR.
    api("net.java.dev.jna:jna:5.19.1@aar")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.14.11")
    testImplementation("org.json:json:20260814")
    // Ed25519 signer for tests only — production code is verify-only.
    testImplementation("net.i2p.crypto:eddsa:0.3.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

// Lint the Android Kotlin sources with ktlint. AGP 9 built-in Kotlin leaves
// `kotlin.sourceSets` empty, so ktlint-gradle only covers `.kts`; this shim
// restores enforcement over `src/**/*.kt`. See the script header for details.
apply(from = rootProject.file("gradle/ktlint-android-sources.gradle.kts"))
