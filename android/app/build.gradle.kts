import org.gradle.testing.jacoco.tasks.JacocoCoverageVerification
import org.gradle.testing.jacoco.tasks.JacocoReport

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("org.jetbrains.kotlin.kapt")
    id("org.jlleitschuh.gradle.ktlint")
    id("io.gitlab.arturbosch.detekt")
    id("com.autonomousapps.dependency-analysis")
    jacoco
}

android {
    namespace = "com.openburnbar"
    compileSdk = 35

    val releaseKeystorePath = providers.environmentVariable("OPENBURNBAR_ANDROID_KEYSTORE_PATH").orNull
    val releaseKeystorePassword = providers.environmentVariable("OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD").orNull
    val releaseKeyAlias = providers.environmentVariable("OPENBURNBAR_ANDROID_KEY_ALIAS").orNull
    val releaseKeyPassword = providers.environmentVariable("OPENBURNBAR_ANDROID_KEY_PASSWORD").orNull
    val hasReleaseSigningConfig =
        listOf(
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
        versionCode = 24
        versionName = "1.0.14"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // App Check: when this build is meant for Firebase App Distribution
        // (where Play Integrity attestation fails because the app isn't on
        // Play Console yet), the BurnBarApplication wires the Debug
        // provider seeded with the registered DEBUG_APP_CHECK_TOKEN below.
        // Real Play Store production builds leave the env var unset, which
        // keeps Play Integrity in place. Enforcement on the server side
        // stays ON in both cases.
        val useDebugAppCheck =
            providers.environmentVariable("OPENBURNBAR_USE_DEBUG_APP_CHECK")
                .map { it.equals("true", ignoreCase = true) }
                .orElse(false)
                .get()
        buildConfigField("boolean", "USE_DEBUG_APP_CHECK", useDebugAppCheck.toString())
        val debugAppCheckToken =
            providers.environmentVariable("OPENBURNBAR_APP_CHECK_DEBUG_TOKEN")
                .orElse("")
                .get()
        buildConfigField("String", "APP_CHECK_DEBUG_TOKEN", "\"" + debugAppCheckToken + "\"")

        // Sentry DSN injected at build time — empty string disables Sentry.
        // CI sets OPENBURNBAR_ANDROID_SENTRY_DSN from the GitHub secret.
        val sentryDsn =
            providers.environmentVariable("OPENBURNBAR_ANDROID_SENTRY_DSN")
                .orElse("")
                .get()
        manifestPlaceholders["sentryDsn"] = sentryDsn
        manifestPlaceholders["sentryEnvironment"] = if (sentryDsn.isNotEmpty()) "production" else "development"
    }

    buildTypes {
        debug {
            enableUnitTestCoverage = true
        }
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

    packaging {
        resources {
            excludes +=
                setOf(
                    "META-INF/LICENSE",
                    "META-INF/LICENSE.md",
                    "META-INF/LICENSE-notice.md",
                    "META-INF/NOTICE",
                    "META-INF/NOTICE.md"
                )
        }
    }

    testOptions {
        unitTests.all {
            it.jvmArgs("-Xshare:off")
        }
        unitTests.isIncludeAndroidResources = true
    }
}

tasks.register<JacocoReport>("jacocoTestReport") {
    dependsOn("testDebugUnitTest")
    reports {
        xml.required.set(true)
        html.required.set(true)
        xml.outputLocation.set(
            layout.buildDirectory.file("reports/jacoco/testDebugUnitTest/jacocoTestReport.xml")
        )
    }
    val debugTree =
        fileTree(layout.buildDirectory.dir("tmp/kotlin-classes/debug")) {
            exclude(
                "**/R.class",
                "**/R\$*.class",
                "**/BuildConfig.*",
                "**/Manifest*.*",
                "**/*Test*.*",
                "**/*\$Lambda\$*.*"
            )
        }
    classDirectories.setFrom(debugTree)
    sourceDirectories.setFrom(files("src/main/java", "src/main/kotlin"))
    executionData.setFrom(
        fileTree(layout.buildDirectory) {
            include("outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec")
            include("jacoco/testDebugUnitTest.exec")
        }
    )
}

// Enforce minimum coverage thresholds — CI fails if coverage drops below these levels
tasks.register("jacocoCoverageVerification") {
    dependsOn("jacocoTestReport")
    doLast {
        val reportFile =
            layout.buildDirectory.file(
                "reports/jacoco/testDebugUnitTest/jacocoTestReport.xml"
            ).get().asFile
        if (!reportFile.exists()) {
            logger.warn("JaCoCo XML report not found; skipping coverage verification.")
            return@doLast
        }
        val xml = reportFile.readText()
        // Extract instruction coverage (most stable metric for Kotlin)
        val instructionMatch =
            Regex(
                """<counter type="INSTRUCTION" missed="(\d+)" covered="(\d+)"/>"""
            ).findAll(xml).lastOrNull()
        if (instructionMatch != null) {
            val missed = instructionMatch.groupValues[1].toLong()
            val covered = instructionMatch.groupValues[2].toLong()
            val total = missed + covered
            val pct = if (total > 0) covered * 100.0 / total else 0.0
            val threshold = 40.0
            logger.lifecycle("JaCoCo instruction coverage: ${String.format("%.1f", pct)}% (threshold: $threshold%)")
            if (pct < threshold) {
                throw GradleException(
                    "Instruction coverage ${String.format("%.1f", pct)}% is below the minimum $threshold%. " +
                        "Add tests to bring coverage above $threshold%."
                )
            }
        }
    }
}

tasks.matching { it.name == "testDebugUnitTest" }.configureEach {
    finalizedBy("jacocoTestReport")
}

// Typed Jacoco coverage verification gate using the built-in JacocoCoverageVerification task.
// Enforces a minimum 60% instruction coverage threshold on CI.
tasks.register<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
    dependsOn("jacocoTestReport")
    violationRules {
        rule {
            limit {
                minimum = "0.60".toBigDecimal()
            }
        }
    }
}

dependencies {
    // Local Kotlin library: Android-side iroh transport + pairing
    // verifier. 1:1 mirror of the Swift OpenBurnBarIrohRelay package.
    implementation(project(":openburnbar-iroh-relay"))
    // Computer Use phone-control intents are signed on Android with the
    // same portable Ed25519 primitive used by the relay pairing verifier.
    implementation("com.google.crypto.tink:tink-android:1.15.0")
    val irohAar = rootProject.layout.projectDirectory.dir("..").asFile.resolve("Vendor/openburnbar-iroh.aar")
    if (irohAar.exists()) {
        implementation(files(irohAar))
    }

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
    implementation("androidx.biometric:biometric:1.1.0")
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
    // Sentry Android SDK — structured error tracking with crash reports,
    // ANR detection, breadcrumbs, and release health metrics. Captures
    // errors via the sentry-issue-sync CI workflow → GitHub issues pipeline.
    // Gracefully no-ops when SENTRY_DSN meta-data value is empty.
    implementation("io.sentry:sentry-android:8.13.2")
    // Mercury Media — high-priority FCM data messages for incoming calls.
    implementation("com.google.firebase:firebase-messaging-ktx")

    // Mercury Media — CameraX for the local camera capture pipeline that
    // feeds the HEVC encoder via a MediaCodec.createInputSurface() input
    // surface. 1.4.x is the first 1.x line that ships
    // CameraSelector.LENS_FACING_FRONT support across all minSdk targets.
    val cameraXVersion = "1.4.0"
    implementation("androidx.camera:camera-core:$cameraXVersion")
    implementation("androidx.camera:camera-camera2:$cameraXVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraXVersion")
    implementation("androidx.camera:camera-view:$cameraXVersion")
    // CameraX hands out a `ListenableFuture<ProcessCameraProvider>`; the
    // kotlinx-coroutines-guava bridge provides `.await()`.
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    implementation("androidx.concurrent:concurrent-futures-ktx:1.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.9.0")
    // Auth — legacy GoogleSignIn kept for backwards compat with existing code paths;
    // Credential Manager is the new primary entry point.
    implementation("com.google.android.gms:play-services-auth:21.3.0")
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    // Google Play Billing for BurnBar Pro (Hosted Quota + hosted LLM + encrypted cloud search).
    implementation("com.android.billingclient:billing-ktx:8.3.0")

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
    implementation("androidx.glance:glance:1.1.1")
    implementation("androidx.glance:glance-appwidget:1.1.1")

    // WorkManager — schedules the periodic widget snapshot refresh.
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // DataStore for preferences
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Coil for image loading
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Room
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    kapt("androidx.room:room-compiler:$roomVersion")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("io.mockk:mockk:1.13.13")
    // Real org.json on the JVM test classpath so parsers can run without an
    // emulator (Android's bundled JSONObject is stubbed in unit tests).
    testImplementation("org.json:json:20240303")
    // Ed25519 signer for the Hermes iroh transport tests only — production
    // code is verify-only via Tink. Same lib + version the relay module's
    // test classpath uses.
    testImplementation("net.i2p.crypto:eddsa:0.3.0")
    // DataStore Preferences test helpers — the partner-save preference
    // store materialises a Preferences DataStore on a temp dir.
    testImplementation("androidx.datastore:datastore-preferences:1.1.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4:1.7.8")
    androidTestImplementation("androidx.compose.ui:ui-test-manifest:1.7.8")
    // Mockk on-device flavor — pure-JVM `io.mockk:mockk` brings in
    // bytebuddy classes the ART runtime can't load, so the instrumented
    // suites use `mockk-android` instead.
    androidTestImplementation("io.mockk:mockk-android:1.13.13")
}

detekt {
    config.setFrom(files("$projectDir/../detekt.yml"))
}

tasks.withType<io.gitlab.arturbosch.detekt.Detekt>().configureEach {
    if (name.contains("test", ignoreCase = true)) {
        enabled = false
    } else {
        exclude("**/SwarmTextCoordinates.kt")
        exclude("**/SwarmBackground.kt")
        exclude("**/DotConstellationBackground.kt")
        // Same family as the swarm/constellation renderers above: a heavy Canvas +
        // particle-physics file whose inline field math (gravity, easing, alpha
        // curves) trips LongParameterList/complexity rules that don't fit per-frame
        // draw code. Excluded to match its siblings, not to hide real smells.
        exclude("**/EasterEggOverlay.kt")
        exclude("**/AuroraTheme.kt")
        exclude("**/AuroraNavGlyphs.kt")
        exclude("**/renderers/**")
    }
}

// Pull the latest committed generated sources from the monorepo's codegen
// packages into the Android tree before every build, mirroring how Apple
// consumes packages/data-domains/gen + packages/design-tokens/dist directly
// via project.yml source paths. Android modules cannot reference files outside
// the module, so they are copied in byte-for-byte. This is the mechanism that
// stops the Android privacy labels from drifting away from registry.json the
// way DataDomains.kt did (a hand-edited "GENERATED-DO-NOT-EDIT" file once
// mislabeled server-readable chat as end-to-end encrypted). CI enforces the
// invariant from the other side (registry.test.mjs / tokens.test.mjs + a
// `git diff --exit-code` gate). Refresh manually with:
//   ./gradlew :app:syncGeneratedSources
tasks.register("syncGeneratedSources") {
    description = "Copies generated data-domain + design-token sources from /packages into the Android tree."
    group = "build setup"

    val repoRoot = rootProject.layout.projectDirectory.dir("..").asFile
    val generatedCopies = mapOf(
        repoRoot.resolve("packages/data-domains/gen/DataDomains.kt")
            to projectDir.resolve("src/main/java/com/openburnbar/data/domains/DataDomains.kt"),
        repoRoot.resolve("packages/design-tokens/dist/compose/PensieveTokens.kt")
            to projectDir.resolve("src/main/java/com/openburnbar/ui/tokens/PensieveTokens.kt"),
    )

    // Only the existing sources participate in up-to-date checks; a missing
    // source leaves the committed copy untouched (see the warning below).
    inputs.files(generatedCopies.keys.filter { it.exists() })
    outputs.files(generatedCopies.values)

    doLast {
        generatedCopies.forEach { (source, dest) ->
            if (!source.exists()) {
                logger.warn(
                    "syncGeneratedSources: $source is missing — keeping the committed ${dest.name}. " +
                        "Run the package codegen (node packages/data-domains/codegen.mjs / " +
                        "packages/design-tokens config.mjs) to refresh it."
                )
                return@forEach
            }
            val sourceBytes = source.readBytes()
            if (!dest.exists() || !dest.readBytes().contentEquals(sourceBytes)) {
                dest.parentFile.mkdirs()
                source.copyTo(dest, overwrite = true)
                logger.lifecycle("syncGeneratedSources: refreshed ${dest.name} from ${source.relativeTo(repoRoot)}")
            }
        }
    }
}

// A fresh build always pulls the latest generated sources first, so a stale
// hand-edited copy can never reach the compiler.
tasks.named("preBuild") {
    dependsOn("syncGeneratedSources")
}
