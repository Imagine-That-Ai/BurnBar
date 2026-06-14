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
}

android {
    namespace = "com.openburnbar.irohrelay"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
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

dependencies {
    // Kotlinx-serialization for the HermesRealtimeRelayFrame JSON wire
    // shape. Same data model the iOS side encodes via JSONEncoder.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // Tink — Ed25519 verifier compatible with iOS Curve25519.Signing on
    // every API level from 26 up. The JDK's java.security.Signature
    // Ed25519 algorithm only landed in API 31+, so Tink is the portable
    // primitive across our minSdk range.
    implementation("com.google.crypto.tink:tink-android:1.15.0")

    // JNA 5.19.0 ships 16 KB page-size aligned native libjnidispatch slices.
    // UniFFI's generated Kotlin bindings use JNA to load the Rust AAR.
    api("net.java.dev.jna:jna:5.19.0@aar")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.13.13")
    testImplementation("org.json:json:20240303")
    // Ed25519 signer for tests only — production code is verify-only.
    testImplementation("net.i2p.crypto:eddsa:0.3.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

// Lint the Android Kotlin sources with ktlint. AGP 9 built-in Kotlin leaves
// `kotlin.sourceSets` empty, so ktlint-gradle only covers `.kts`; this shim
// restores enforcement over `src/**/*.kt`. See the script header for details.
apply(from = rootProject.file("gradle/ktlint-android-sources.gradle.kts"))
