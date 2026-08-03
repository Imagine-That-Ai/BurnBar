// Android-library mirror of the BurnBar Remote Rust engine UniFFI surface.
//
// The generated bindings land under src/main/java/uniffi/burnbar_remote/ after
// scripts/build-burnbar-remote-android-aar.sh runs. Until then the public bridge
// compiles with deterministic Kotlin fallbacks and reports nativeUnavailable.
import org.gradle.api.tasks.testing.Test

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("org.jlleitschuh.gradle.ktlint")
}

android {
    namespace = "com.openburnbar.remote"
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
}

dependencies {
    api("net.java.dev.jna:jna:5.19.1@aar")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("net.java.dev.jna:jna:5.19.1")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    val committedRemoteAar = rootProject.layout.projectDirectory.dir("..").asFile.resolve("Vendor/burnbar-remote.aar")
    if (committedRemoteAar.exists()) {
        androidTestImplementation(files(committedRemoteAar))
    }
}

tasks.withType<Test>().configureEach {
    val expectNative = providers.systemProperty("burnbar.remote.expectNative").orElse("false")
    systemProperty("burnbar.remote.expectNative", expectNative.get())
    providers.systemProperty("burnbar.remote.nativeLibraryPath").orNull?.let { nativeLibraryPath ->
        val resolvedNativeLibraryPath = rootProject.file(nativeLibraryPath).absolutePath
        systemProperty("burnbar.remote.nativeLibraryPath", resolvedNativeLibraryPath)
        systemProperty("jna.library.path", resolvedNativeLibraryPath)
        systemProperty("java.library.path", resolvedNativeLibraryPath)
    }
}

apply(from = rootProject.file("gradle/ktlint-android-sources.gradle.kts"))
