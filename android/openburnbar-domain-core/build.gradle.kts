plugins {
    id("com.android.library")
    id("org.jlleitschuh.gradle.ktlint")
}

val domainCoreAar =
    rootProject.layout.projectDirectory.dir("..").asFile
        .resolve("Vendor/openburnbar-domain-core.aar")
val generatedDomainCoreAndroidTestAssetsDir =
    layout.buildDirectory.dir("generated/domainCoreIdentityAndroidTest/assets")
val stageDomainCoreIdentityForAndroidTest =
    tasks.register<Sync>("stageDomainCoreIdentityForAndroidTest") {
        from(zipTree(domainCoreAar)) {
            include("META-INF/openburnbar-domain-core-source.sha256")
            eachFile { path = name }
            includeEmptyDirs = false
        }
        from(rootProject.file("../crates/openburnbar-domain-core/union-abi-manifest.json"))
        into(generatedDomainCoreAndroidTestAssetsDir)
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

    sourceSets {
        getByName("androidTest").assets.directories.add(
            generatedDomainCoreAndroidTestAssetsDir.get().asFile.absolutePath,
        )
    }

    lint {
        lintConfig = file("lint.xml")
    }
}

dependencies {
    // UniFFI Kotlin bindings load the Rust cdylib through JNA.
    api("net.java.dev.jna:jna:5.19.1@aar")

    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    // The production app attaches the native-only AAR directly. Attach it to
    // the test APK as well so the instrumentation smoke exercises Android ELF,
    // not a host substitute.
    if (domainCoreAar.exists()) {
        androidTestImplementation(files(domainCoreAar))
    }
}

tasks.matching { it.name == "mergeDebugAndroidTestAssets" }.configureEach {
    dependsOn(stageDomainCoreIdentityForAndroidTest)
}

apply(from = rootProject.file("gradle/ktlint-android-sources.gradle.kts"))
