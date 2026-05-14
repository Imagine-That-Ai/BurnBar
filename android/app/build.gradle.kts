plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

android {
    namespace = "com.openburnbar"
    compileSdk = 35

    val releaseKeystorePath = providers.environmentVariable("OPENBURNBAR_ANDROID_KEYSTORE_PATH").orNull
    val releaseKeystorePassword = providers.environmentVariable("OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD").orNull
    val releaseKeyAlias = providers.environmentVariable("OPENBURNBAR_ANDROID_KEY_ALIAS").orNull
    val releaseKeyPassword = providers.environmentVariable("OPENBURNBAR_ANDROID_KEY_PASSWORD").orNull
    val hasReleaseSigningConfig = listOf(
        releaseKeystorePath,
        releaseKeystorePassword,
        releaseKeyAlias,
        releaseKeyPassword
    ).all { !it.isNullOrBlank() }

    signingConfigs {
        if (hasReleaseSigningConfig) {
            create("releaseUpload") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    defaultConfig {
        applicationId = "com.openburnbar"
        minSdk = 26
        targetSdk = 35
        versionCode = 12
        versionName = "1.0.4"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // App Check: when this build is meant for Firebase App Distribution
        // (where Play Integrity attestation fails because the app isn't on
        // Play Console yet), the BurnBarApplication wires the Debug
        // provider seeded with the registered DEBUG_APP_CHECK_TOKEN below.
        // Real Play Store production builds leave the env var unset, which
        // keeps Play Integrity in place. Enforcement on the server side
        // stays ON in both cases.
        val useDebugAppCheck = providers.environmentVariable("OPENBURNBAR_USE_DEBUG_APP_CHECK")
            .map { it.equals("true", ignoreCase = true) }
            .orElse(false)
            .get()
        buildConfigField("boolean", "USE_DEBUG_APP_CHECK", useDebugAppCheck.toString())
        val debugAppCheckToken = providers.environmentVariable("OPENBURNBAR_APP_CHECK_DEBUG_TOKEN")
            .orElse("")
            .get()
        buildConfigField("String", "APP_CHECK_DEBUG_TOKEN", "\"" + debugAppCheckToken + "\"")
    }

    buildTypes {
        release {
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("releaseUpload")
            }
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    // Compose BOM
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    // Compose UI
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.foundation:foundation")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Activity & Lifecycle
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Firebase
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-auth-ktx")
    implementation("com.google.firebase:firebase-appcheck-playintegrity")
    // Bundled in release as well: BurnBarApplication switches to the Debug
    // provider when this APK is built for Firebase App Distribution (env
    // var OPENBURNBAR_USE_DEBUG_APP_CHECK=true), so Play Integrity-rejected
    // builds can still pass enforced App Check via a registered token.
    // Real Play Store builds simply leave the env var unset and use Play
    // Integrity exclusively.
    implementation("com.google.firebase:firebase-appcheck-debug")
    implementation("com.google.firebase:firebase-firestore-ktx")
    implementation("com.google.firebase:firebase-functions-ktx")
    implementation("com.google.firebase:firebase-crashlytics-ktx")
    // Auth — legacy GoogleSignIn kept for backwards compat with existing code paths;
    // Credential Manager is the new primary entry point.
    implementation("com.google.android.gms:play-services-auth:21.3.0")
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")


    // OkHttp + WebSocket for Hermes
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Vico 2.x — Compose-first chart library for Insights
    implementation("com.patrykandpatrick.vico:compose-m3:2.1.2")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")

    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // Glance for Widget
    implementation("androidx.glance:glance-appwidget:1.1.1")

    // WorkManager — schedules the periodic widget snapshot refresh.
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // DataStore for preferences
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Coil for image loading
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("io.mockk:mockk:1.13.13")
    // Real org.json on the JVM test classpath so parsers can run without an
    // emulator (Android's bundled JSONObject is stubbed in unit tests).
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4:1.7.8")
    androidTestImplementation("androidx.compose.ui:ui-test-manifest:1.7.8")
}
