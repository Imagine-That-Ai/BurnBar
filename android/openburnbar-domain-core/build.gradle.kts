plugins {
    id("com.android.library")
    id("org.jlleitschuh.gradle.ktlint")
}

android {
    namespace = "com.openburnbar.domaincore"
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
    // UniFFI Kotlin bindings load the Rust cdylib through JNA.
    api("net.java.dev.jna:jna:5.19.0@aar")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    // The production app attaches the native-only AAR directly. Attach it to
    // the test APK as well so the instrumentation smoke exercises Android ELF,
    // not a host substitute.
    val domainCoreAar =
        rootProject.layout.projectDirectory.dir("..").asFile
            .resolve("Vendor/openburnbar-domain-core.aar")
    if (domainCoreAar.exists()) {
        androidTestImplementation(files(domainCoreAar))
    }
}

apply(from = rootProject.file("gradle/ktlint-android-sources.gradle.kts"))
