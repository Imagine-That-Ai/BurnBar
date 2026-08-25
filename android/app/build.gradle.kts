import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import java.util.Properties
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.gradle.api.tasks.testing.Test
import org.gradle.testing.jacoco.tasks.JacocoCoverageVerification
import org.gradle.testing.jacoco.tasks.JacocoReport

abstract class GenerateDomainCoreBuildProfileAsset : DefaultTask() {
    @get:Input
    abstract val profileJson: Property<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val file = outputDirectory.file("domain-core-build-profile.json").get().asFile
        file.parentFile.mkdirs()
        file.writeText(profileJson.get())
    }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("com.android.legacy-kapt")
    id("org.jlleitschuh.gradle.ktlint")
    id("dev.detekt")
    id("com.autonomousapps.dependency-analysis")
    // Sentry Android Gradle plugin: uploads R8/ProGuard mapping files for the
    // minified release variant so the crash stacks Sentry receives (via the
    // io.sentry:sentry-android runtime SDK) are deobfuscated and readable.
    // Without this, every release crash report is an unreadable obfuscated
    // trace. 6.x uses the AGP 9 DSL and pairs with the sentry-android 8.x SDK. Declared with an inline
    // version (not in the root plugins block) so the mapping-upload + native
    // gradle config stays scoped to :app. Upload is auth-token gated below so
    // local/offline builds without Sentry credentials still succeed.
    id("io.sentry.android.gradle") version "6.19.0"
    // Baseline-profile consumer: wires the :macrobenchmark producer so
    // `./gradlew :app:generateBaselineProfile` captures an app-specific
    // profile (library profiles for Compose/activity already ship via the
    // transitive profileinstaller; this adds AOT for BurnBar's own code).
    id("androidx.baselineprofile")
    jacoco
}

val openBurnBarAppVersionName =
    providers.gradleProperty("openBurnBarAppVersionName")
        .orElse("1.0.40")
val openBurnBarCompileSdk: Int by rootProject.extra
val openBurnBarTargetSdk: Int by rootProject.extra
fun Any?.asJsonMap(): Map<*, *> = this as? Map<*, *> ?: emptyMap<Any, Any>()
fun Any?.asJsonList(): List<*> = this as? List<*> ?: emptyList<Any>()

val domainCoreProfileCatalogFile = rootProject.projectDir.resolve("../config/domain-core-build-profiles.json")
val domainCoreProfileCatalog = JsonSlurper().parse(domainCoreProfileCatalogFile).asJsonMap()
require((domainCoreProfileCatalog["schemaVersion"] as? Number)?.toInt() == 1) { "Unsupported domain-core profile schema" }
val domainCoreDomains = domainCoreProfileCatalog["domains"].asJsonList().map { it as? String ?: error("Invalid domain-core domain") }
val domainCoreProfiles = domainCoreProfileCatalog["profiles"].asJsonMap()
val domainCoreProfileName = providers.environmentVariable("OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE").orElse("developer").get()
val domainCoreProfile = domainCoreProfiles[domainCoreProfileName].asJsonMap()
require(domainCoreProfile.isNotEmpty()) { "Unknown domain-core build profile: $domainCoreProfileName" }
val domainCoreAuthority = domainCoreProfile["artifactAuthority"] as? String ?: error("Missing domain-core artifact authority")
val domainCoreDistribution = domainCoreProfile["distribution"] as? String ?: error("Missing domain-core distribution")
val domainCoreChannel = domainCoreProfile["rolloutChannel"] as? String ?: ""
val domainCoreEvidenceEnabled = domainCoreProfile["evidenceEnabled"] as? Boolean ?: error("Missing domain-core evidence policy")
val domainCoreCandidateCommit = providers.environmentVariable("OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT").orElse("").get()
val domainCoreExpectedVersion = providers.environmentVariable("OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION").orElse("").get()
val domainCoreExpectedAbiVersionRaw = providers.environmentVariable("OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION").orElse("").get()
val domainCoreExpectedSourceSha256 = providers.environmentVariable("OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256").orElse("").get()
val domainCoreCandidateValues = listOf(
    domainCoreCandidateCommit,
    domainCoreExpectedVersion,
    domainCoreExpectedAbiVersionRaw,
    domainCoreExpectedSourceSha256
)
val domainCoreCandidateIdentityPresent = domainCoreCandidateValues.any(String::isNotEmpty)
val canonicalDomainCoreSemVer = Regex(
    """^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)""" +
        """(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?""" +
        """(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?${'$'}"""
)
val domainCoreExpectedAbiVersion = domainCoreExpectedAbiVersionRaw.toLongOrNull() ?: 0L
if (domainCoreCandidateIdentityPresent) {
    require(Regex("^[0-9a-f]{40}$").matches(domainCoreCandidateCommit)) {
        "Domain-core candidate commit must be a lowercase 40-character Git commit"
    }
    require(domainCoreExpectedVersion.toByteArray().size <= 64 && canonicalDomainCoreSemVer.matches(domainCoreExpectedVersion)) {
        "Domain-core expected version must be canonical SemVer with at most 64 bytes"
    }
    require(
        Regex("^[1-9]\\d*$").matches(domainCoreExpectedAbiVersionRaw) &&
            domainCoreExpectedAbiVersion in 1L..4_294_967_295L
    ) { "Domain-core expected ABI version must be a canonical positive uint32" }
    require(Regex("^[0-9a-f]{64}$").matches(domainCoreExpectedSourceSha256)) {
        "Domain-core expected source SHA-256 must be 64 lowercase hexadecimal characters"
    }
}
val domainCoreCandidateIdentityWire = if (domainCoreCandidateIdentityPresent) {
    domainCoreCandidateValues.joinToString("|")
} else {
    ""
}
val canonicalDomainCoreModes = domainCoreProfile["modes"].asJsonMap().mapKeys { it.key as String }.mapValues { it.value as String }
require(canonicalDomainCoreModes.keys == domainCoreDomains.toSet()) { "Domain-core profile modes must exactly cover catalog domains" }
require(canonicalDomainCoreModes.values.all { it in setOf("legacy", "shadow", "rust") }) { "Invalid domain-core mode" }
val canonicalDomainCoreIdentity = mapOf(
    "developer" to ("development" to "development"),
    "public-production" to ("signed" to "public"),
    "public-production-rollback" to ("signed" to "public"),
    "internal" to ("signed" to "internal"),
    "beta" to ("signed" to "beta")
)[domainCoreProfileName] ?: error("Unknown domain-core profile identity")
require(domainCoreAuthority == canonicalDomainCoreIdentity.first && domainCoreDistribution == canonicalDomainCoreIdentity.second) {
    "Domain-core profile authority/distribution does not match its canonical identity"
}
require(domainCoreAuthority != "signed" || domainCoreCandidateIdentityPresent) {
    "Signed domain-core profiles require a complete expected candidate identity"
}
if (domainCoreAuthority == "signed" && domainCoreDistribution == "public") {
    require(!domainCoreEvidenceEnabled && domainCoreChannel.isEmpty() && "shadow" !in canonicalDomainCoreModes.values) {
        "Public domain-core profile cannot enable evidence, rollout channel, or shadow mode"
    }
}
if (domainCoreAuthority == "signed" && domainCoreDistribution in setOf("internal", "beta")) {
    require(domainCoreEvidenceEnabled && domainCoreChannel == domainCoreDistribution && canonicalDomainCoreModes["quota"] == "shadow") {
        "Internal/beta domain-core profile must enable the matching channel and quota shadow"
    }
}

fun developerDomainCoreMode(domain: String, vararg environmentKeys: String): String {
    if (domainCoreAuthority != "development") return canonicalDomainCoreModes.getValue(domain)
    val raw = environmentKeys.firstNotNullOfOrNull { providers.environmentVariable(it).orNull }?.trim()?.lowercase()
    return if (raw in setOf("legacy", "shadow", "rust")) raw!! else canonicalDomainCoreModes.getValue(domain)
}

val cloudVaultSearchDomainCoreMode = developerDomainCoreMode(
    "cloudVaultSearch",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
    "OPENBURNBAR_CLOUDVAULT_SEARCH_MODE"
)
val cloudVaultDocumentRewrapMode = developerDomainCoreMode("cloudVaultRewrap", "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE")
val cloudVaultDomainCoreMode = developerDomainCoreMode(
    "cloudVault",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
    "OPENBURNBAR_CLOUDVAULT_DOMAIN_MODE"
)
val hermesDomainCoreMode = developerDomainCoreMode("hermes", "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE")
val generatedDomainCoreProfileAssetsDir = layout.buildDirectory.dir("generated/domainCoreProfile/assets")
val resolvedDomainCoreProfileArtifact = mapOf(
    "schemaVersion" to 1,
    "name" to domainCoreProfileName,
    "artifactAuthority" to domainCoreAuthority,
    "distribution" to domainCoreDistribution,
    "rolloutChannel" to domainCoreChannel.ifEmpty { null },
    "evidenceEnabled" to domainCoreEvidenceEnabled,
    "candidateIdentity" to if (domainCoreCandidateIdentityPresent) {
        mapOf(
            "candidateCommit" to domainCoreCandidateCommit,
            "coreVersion" to domainCoreExpectedVersion,
            "abiVersion" to domainCoreExpectedAbiVersion,
            "sourceSha256" to domainCoreExpectedSourceSha256
        )
    } else {
        null
    },
    "modes" to canonicalDomainCoreModes
)
val generateDomainCoreBuildProfileAsset = tasks.register<GenerateDomainCoreBuildProfileAsset>("generateDomainCoreBuildProfileAsset") {
    profileJson.set(JsonOutput.prettyPrint(JsonOutput.toJson(resolvedDomainCoreProfileArtifact)) + "\n")
    outputDirectory.set(generatedDomainCoreProfileAssetsDir)
}

/**
 * Resolve a build-time secret/config value from the environment first, then the
 * gitignored local.properties, else empty string. Used for the Amplitude key so
 * no key is ever committed and absence simply leaves analytics dark.
 */
fun resolveAmplitudeConfig(envVar: String, localPropertyKey: String): String {
    val fromEnv = providers.environmentVariable(envVar).orNull?.trim()
    if (!fromEnv.isNullOrBlank()) return fromEnv
    val localPropsFile = rootProject.layout.projectDirectory.file("local.properties").asFile
    if (localPropsFile.exists()) {
        val props = Properties()
        val stream = localPropsFile.inputStream()
        try {
            props.load(stream)
        } finally {
            stream.close()
        }
        return props.getProperty(localPropertyKey)?.trim().orEmpty()
    }
    return ""
}

gradle.taskGraph.whenReady {
    val releaseTask =
        allTasks.firstOrNull { task ->
            val artifactTask =
                listOf("assemble", "bundle", "package", "install").any(task.name::startsWith) &&
                    task.name.endsWith("Release")
            val distributionTask =
                listOf("publish", "upload").any(task.name::startsWith) && task.name.contains("Release")
            task.path.startsWith("${project.path}:") &&
                (artifactTask || distributionTask)
        }
    if (releaseTask != null) {
        if (domainCoreAuthority != "signed") {
            throw GradleException(
                "Android release artifact task ${releaseTask.path} requires " +
                    "OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE to resolve to a signed profile"
            )
        }
    }
}

android {
    namespace = "com.openburnbar"
    compileSdk = openBurnBarCompileSdk

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
        targetSdk = openBurnBarTargetSdk
        versionCode = 48
        versionName = openBurnBarAppVersionName.get()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        buildConfigField(
            "String",
            "CLOUDVAULT_SEARCH_DOMAIN_CORE_MODE",
            "\"$cloudVaultSearchDomainCoreMode\""
        )
        buildConfigField(
            "String",
            "CLOUDVAULT_REWRAP_DOMAIN_CORE_MODE",
            "\"$cloudVaultDocumentRewrapMode\""
        )
        buildConfigField("String", "CLOUDVAULT_DOMAIN_CORE_MODE", "\"$cloudVaultDomainCoreMode\"")
        buildConfigField("String", "HERMES_DOMAIN_CORE_MODE", "\"$hermesDomainCoreMode\"")
        buildConfigField("String", "QUOTA_DOMAIN_CORE_MODE", "\"${canonicalDomainCoreModes.getValue("quota")}\"")
        buildConfigField("String", "PRICING_DOMAIN_CORE_MODE", "\"${canonicalDomainCoreModes.getValue("pricing")}\"")
        buildConfigField("String", "DOMAIN_CORE_BUILD_PROFILE", "\"$domainCoreProfileName\"")
        buildConfigField("String", "DOMAIN_CORE_BUILD_AUTHORITY", "\"$domainCoreAuthority\"")
        buildConfigField("String", "DOMAIN_CORE_DISTRIBUTION", "\"$domainCoreDistribution\"")
        buildConfigField("String", "DOMAIN_CORE_ROLLOUT_CHANNEL", "\"$domainCoreChannel\"")
        buildConfigField("boolean", "DOMAIN_CORE_EVIDENCE_ENABLED", domainCoreEvidenceEnabled.toString())
        buildConfigField("String", "DOMAIN_CORE_CANDIDATE_IDENTITY", "\"$domainCoreCandidateIdentityWire\"")

        // Sentry DSN injected at build time — empty string disables Sentry.
        // CI sets OPENBURNBAR_ANDROID_SENTRY_DSN from the GitHub secret.
        val sentryDsn =
            providers.environmentVariable("OPENBURNBAR_ANDROID_SENTRY_DSN")
                .orElse("")
                .get()
        manifestPlaceholders["sentryDsn"] = sentryDsn
        manifestPlaceholders["sentryEnvironment"] = if (sentryDsn.isNotEmpty()) "production" else "development"

        // Amplitude (opt-in analytics) — key injected at build time, NEVER
        // committed. Resolution order: OPENBURNBAR_AMPLITUDE_API_KEY env var
        // (CI secret), then `amplitude.apiKey` in the gitignored local.properties,
        // else empty. An empty key leaves the analytics recorder dark by
        // construction (see AnalyticsManager / Analytics.canSend), so OSS builds
        // and CI without the secret never initialize the SDK or hit the network.
        val amplitudeApiKey = resolveAmplitudeConfig("OPENBURNBAR_AMPLITUDE_API_KEY", "amplitude.apiKey")
        val amplitudeServerZone = resolveAmplitudeConfig("OPENBURNBAR_AMPLITUDE_SERVER_ZONE", "amplitude.serverZone")
            .ifBlank { "US" }
        buildConfigField("String", "AMPLITUDE_API_KEY", "\"" + amplitudeApiKey + "\"")
        buildConfigField("String", "AMPLITUDE_SERVER_ZONE", "\"" + amplitudeServerZone + "\"")

        ndk {
            // Android 16 KB page-size devices are 64-bit-first. Keep the APK's
            // native surface on the modern Play-supported ABIs and avoid
            // bundling stale 32-bit JNI slices from transitive AARs.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
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
        isCoreLibraryDesugaringEnabled = true
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
            // org.signal:libsignal-android carries host-side macOS dylibs as
            // Java resources. Android cannot load Mach-O dylibs, and shipping
            // them bloats the APK with non-runtime/test native artifacts.
            excludes += setOf("*.dylib", "**/*.dylib")
        }
        jniLibs {
            // The release identity gate executes this exact AAR library on an
            // arm64 emulator, then compares its digest with the final AAB.
            // Preserve identical ELF bytes across debug-test and release packaging.
            keepDebugSymbols += "**/libopenburnbar_domain_ffi.so"
            // Vendor/openburnbar-iroh.aar ships the same cdylib under two names per ABI;
            // only libopenburnbar_iroh.so is ever loaded (JNA findLibraryName +
            // System.loadLibrary), so drop the byte-identical libuniffi_ duplicate
            // (~41.6MB across the four ABIs in a fat APK).
            excludes += "**/libuniffi_openburnbar_iroh.so"
            // Signal's AAR includes this optional JNI testing companion. The
            // production app does not call testing APIs, and Signal documents
            // this file as safe to exclude when those APIs are unused.
            excludes += "**/libsignal_jni_testing.so"
        }
    }

    testOptions {
        unitTests.all {
            it.jvmArgs("-Xshare:off")
        }
        unitTests.isIncludeAndroidResources = true
    }

    sourceSets {
        getByName("test").resources.directories.add(
            rootProject.layout.projectDirectory.dir("../tests/fixtures/domain-core/cloudvault/v1").asFile.absolutePath
        )
        getByName("androidTest").assets.directories.add(
            rootProject.layout.projectDirectory.dir("../tests/fixtures/domain-core/cloudvault/v1").asFile.absolutePath
        )
    }
}
tasks.withType<Test>().configureEach {
    providers.systemProperty("openburnbar.domainCore.nativeLibraryPath").orNull?.let { nativeLibraryPath ->
        val resolvedNativeLibraryPath = rootProject.file(nativeLibraryPath).absolutePath
        systemProperty(
            "uniffi.component.openburnbar_domain_ffi.libraryOverride",
            resolvedNativeLibraryPath
        )
    }
}

androidComponents {
    onVariants(selector().all()) { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            generateDomainCoreBuildProfileAsset,
            GenerateDomainCoreBuildProfileAsset::outputDirectory
        )
    }
}

// Sentry mapping upload: only enabled when CI provides SENTRY_AUTH_TOKEN, so
// local/offline release builds (and OSS contributors without Sentry org access)
// still assemble. When the token is present, the plugin auto-uploads the R8
// mapping file for the minified release variant, making release crash stacks
// readable in Sentry. Telemetry (org/build-time pings) is disabled.
val sentryUploadEnabled =
    providers.environmentVariable("SENTRY_AUTH_TOKEN").map { it.isNotBlank() }.orElse(false)
sentry {
    autoUploadProguardMapping.set(sentryUploadEnabled)
    includeProguardMapping.set(sentryUploadEnabled)
    // Don't auto-instrument or inject the native SDK from Gradle; the runtime
    // SDK is wired manifest-side (sentryDsn placeholder) and started by the OS.
    autoInstallation.enabled.set(false)
    tracingInstrumentation.enabled.set(false)
    telemetry.set(false)
}

tasks.register("verifyReleaseFirebaseConfig") {
    group = "verification"
    description = "Fails release builds unless google-services.json is the real BurnBar Android Firebase config."
    val configFile = layout.projectDirectory.file("google-services.json")
    inputs.file(configFile)
    doLast {
        val expectedProjectId = "burnbar"
        val expectedProjectNumber = "246956661961"
        val expectedAppId = "1:246956661961:android:6ffe560abf1a583a480118"
        val expectedPackage = "com.openburnbar"
        val file = configFile.asFile
        if (!file.isFile) {
            throw GradleException("Missing android/app/google-services.json; release builds require the real Firebase config.")
        }

        val payload = JsonSlurper().parse(file).asJsonMap()
        val projectInfo = payload["project_info"].asJsonMap()
        val clients = payload["client"].asJsonList().map { it.asJsonMap() }
        val client =
            clients.firstOrNull {
                it["client_info"]
                    .asJsonMap()["android_client_info"]
                    .asJsonMap()["package_name"]
                    ?.toString() == expectedPackage
            }
                ?: throw GradleException("google-services.json does not contain an Android client for $expectedPackage.")

        val clientInfo = client["client_info"].asJsonMap()
        val androidInfo = clientInfo["android_client_info"].asJsonMap()
        val apiKeys =
            client["api_key"].asJsonList()
                .mapNotNull { it.asJsonMap()["current_key"]?.toString()?.trim() }
        val androidOAuthCertificates =
            client["oauth_client"].asJsonList()
                .map { it.asJsonMap() }
                .filter {
                    it["client_type"]?.toString() == "1" &&
                        it["android_info"].asJsonMap()["package_name"]?.toString() == expectedPackage
                }
                .mapNotNull { it["android_info"].asJsonMap()["certificate_hash"]?.toString()?.trim() }
                .filter { it.length >= 40 }

        fun isPlaceholder(value: String): Boolean {
            val normalized = value.trim()
            return normalized.isBlank() ||
                listOf("YOUR_", "REPLACE_", "EXAMPLE_", "PLACEHOLDER").any { normalized.startsWith(it) }
        }

        val failures = mutableListOf<String>()
        fun requireEqual(label: String, actual: String?, expected: String) {
            if (actual != expected) {
                failures += "$label must be $expected"
            }
        }

        requireEqual("project_id", projectInfo["project_id"]?.toString(), expectedProjectId)
        requireEqual("project_number", projectInfo["project_number"]?.toString(), expectedProjectNumber)
        requireEqual("mobilesdk_app_id", clientInfo["mobilesdk_app_id"]?.toString(), expectedAppId)
        requireEqual("package_name", androidInfo["package_name"]?.toString(), expectedPackage)
        if (apiKeys.none { it.length >= 30 && !isPlaceholder(it) }) {
            failures += "api_key must be a real non-placeholder Firebase Android API key"
        }
        if (androidOAuthCertificates.isEmpty()) {
            failures += "oauth_client must include at least one Android client certificate for $expectedPackage"
        }

        if (failures.isNotEmpty()) {
            throw GradleException(
                "Invalid Android Firebase release config:\n" +
                    failures.joinToString(separator = "\n") { "- $it" }
            )
        }

        logger.lifecycle(
            "Verified Android Firebase release config: project=$expectedProjectId, " +
                "app=$expectedAppId, package=$expectedPackage, apiKeys=${apiKeys.size}, " +
                "androidOAuthCerts=${androidOAuthCertificates.size}"
        )
    }
}

val releaseArtifactTasksRequiringFirebaseConfig =
    setOf(
        "assembleRelease",
        "bundleRelease",
        "packageRelease",
        "publishReleaseBundle",
        "signReleaseBundle"
    )
tasks.matching { it.name in releaseArtifactTasksRequiringFirebaseConfig }.configureEach {
    dependsOn("verifyReleaseFirebaseConfig")
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
        "**/*\$Lambda\$*.*"
    )
val debugCoverageClassDirectories =
    files(
        fileTree(layout.buildDirectory.dir("intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes")) {
            exclude(jacocoClassExcludes)
        },
        fileTree(layout.buildDirectory.dir("intermediates/javac/debug/compileDebugJavaWithJavac/classes")) {
            exclude(jacocoClassExcludes)
        }
    )
val debugCoverageSourceDirectories = files("src/main/java", "src/main/kotlin")
val minimumInstructionCoverage = "0.17".toBigDecimal()

tasks.register<JacocoReport>("jacocoTestReport") {
    dependsOn("testDebugUnitTest")
    reports {
        xml.required.set(true)
        html.required.set(true)
        xml.outputLocation.set(
            layout.buildDirectory.file("reports/jacoco/testDebugUnitTest/jacocoTestReport.xml")
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

// Typed Jacoco coverage verification gate using the built-in JacocoCoverageVerification task.
// Enforces a real full-app instruction coverage regression floor. The previous
// hand-parsed 40% gate read stale pre-AGP 9 Kotlin classes and did not represent
// the shipped app graph; this floor starts from the measured AGP 9 report and
// should be ratcheted upward as Android UI/integration coverage expands.
tasks.register<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
    dependsOn("jacocoTestReport")
    classDirectories.setFrom(debugCoverageClassDirectories)
    sourceDirectories.setFrom(debugCoverageSourceDirectories)
    executionData.setFrom(debugUnitTestCoverageData)
    violationRules {
        rule {
            limit {
                counter = "INSTRUCTION"
                value = "COVEREDRATIO"
                minimum = minimumInstructionCoverage
            }
        }
    }
}

tasks.register("jacocoCoverageVerification") {
    dependsOn("jacocoTestCoverageVerification")
}

dependencies {
    // Local Kotlin library: Android-side iroh transport + pairing
    // verifier. 1:1 mirror of the Swift OpenBurnBarIrohRelay package.
    implementation(project(":openburnbar-iroh-relay"))
    // Shared Rust domain logic. The module owns generated UniFFI Kotlin sources;
    // this app attaches the native-only AAR below when it has been built.
    implementation(project(":openburnbar-domain-core"))
    // Local Kotlin facade for the burnbar-remote UniFFI engine. It runs with
    // deterministic Kotlin fallbacks until Vendor/burnbar-remote.aar exists.
    implementation(project(":burnbar-remote"))
    // Computer Use phone-control intents are signed on Android with the
    // same portable Ed25519 primitive used by the relay pairing verifier.
    implementation("com.google.crypto.tink:tink-android:1.23.0")
    val irohAar = rootProject.layout.projectDirectory.dir("..").asFile.resolve("Vendor/openburnbar-iroh.aar")
    if (irohAar.exists()) {
        implementation(files(irohAar))
    }
    val domainCoreAar =
        rootProject.layout.projectDirectory.dir("..").asFile
            .resolve("Vendor/openburnbar-domain-core.aar")
    if (domainCoreAar.exists()) {
        implementation(files(domainCoreAar))
    }
    val burnBarRemoteAar = rootProject.layout.projectDirectory.dir("..").asFile.resolve("Vendor/burnbar-remote.aar")
    if (burnBarRemoteAar.exists()) {
        implementation(files(burnBarRemoteAar))
    }

    // Baseline profiles: explicit profileinstaller pin (already present
    // transitively via androidx.activity — explicit so the app-specific
    // profile install path is owned, not inherited) + the macrobenchmark
    // module that generates baseline-prof rules on device.
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    "baselineProfile"(project(":macrobenchmark"))

    // Compose BOM
    val composeBom = platform("androidx.compose:compose-bom:2026.08.00")
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
    implementation("androidx.activity:activity-compose:1.13.0")
    // Explicit fragment pin: MainActivity's registerForActivityResult trips
    // lintVital's InvalidFragmentVersionForActivityResult when the resolved
    // transitive androidx.fragment predates 1.3.0.
    implementation("androidx.fragment:fragment-ktx:1.9.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Firebase
    implementation(platform("com.google.firebase:firebase-bom:34.18.0"))
    implementation("com.google.firebase:firebase-auth-ktx")
    implementation("com.google.firebase:firebase-appcheck-playintegrity")
    // The debug provider is compiled only into debuggable developer builds.
    // Distributed artifacts always use Play Integrity and contain no reusable
    // App Check debug credential or provider implementation.
    debugImplementation("com.google.firebase:firebase-appcheck-debug")
    implementation("com.google.firebase:firebase-firestore-ktx")
    implementation("com.google.firebase:firebase-functions-ktx")
    implementation("com.google.firebase:firebase-crashlytics-ktx")
    // F2 — Remote Config gate for the StrongBox/TEE phone-control signing
    // key ramp (`computer_use_phone_control_secure_enclave_key`, default
    // false). See PhoneControlSecureEnclaveKeyPolicy.
    implementation("com.google.firebase:firebase-config-ktx")
    // Sentry Android SDK — structured error tracking with crash reports,
    // ANR detection, breadcrumbs, and release health metrics. Captures
    // errors via the sentry-issue-sync CI workflow → GitHub issues pipeline.
    // Gracefully no-ops when SENTRY_DSN meta-data value is empty.
    implementation("io.sentry:sentry-android:8.53.0")
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
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.11.0")
    // Auth — Credential Manager is the single Google sign-in path; the
    // googleid bridge returns the ID token that Firebase Auth exchanges.
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.2.0")

    // Google Play Billing for BurnBar Pro (Hosted Quota + hosted LLM + encrypted cloud search).
    implementation("com.android.billingclient:billing-ktx:9.1.0")

    // OkHttp + WebSocket for Hermes
    implementation("com.squareup.okhttp3:okhttp:5.5.0")

    // Amplitude — opt-in, consent-gated analytics. The only caller of this SDK
    // is com.openburnbar.analytics.AmplitudeTransport (constructed solely after
    // affirmative opt-in). Autocapture is fully disabled; key is BuildConfig-
    // injected and never committed (absent key ⇒ recorder stays dark).
    implementation("com.amplitude:analytics-android:1.30.1")

    // Vico 2.x — Compose-first chart library for Insights
    implementation("com.patrykandpatrick.vico:compose-m3:3.3.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.11.0")

    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")

    // Official Signal libsignal at-rest HPKE identity seal (v0.94.4 pin).
    implementation("org.signal:libsignal-android:0.101.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // Glance for Widget
    implementation("androidx.glance:glance:1.1.1")
    implementation("androidx.glance:glance-appwidget:1.1.1")

    // WorkManager — schedules the periodic widget snapshot refresh.
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // DataStore for preferences
    implementation("androidx.datastore:datastore-preferences:1.2.1")

    // Coil for image loading
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Room
    val roomVersion = "2.8.4"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    kapt("androidx.room:room-compiler:$roomVersion")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.14.11")
    testImplementation("org.signal:libsignal-client:0.101.0")
    // Android's JNA AAR supplies only device JNI slices. Activated Rust-mode
    // JVM contracts need the desktop JAR's host libjnidispatch resource.
    testImplementation("net.java.dev.jna:jna:5.19.1")
    // Real org.json on the JVM test classpath so parsers can run without an
    // emulator (Android's bundled JSONObject is stubbed in unit tests).
    testImplementation("org.json:json:20260814")
    testImplementation("com.google.code.gson:gson:2.14.0")
    // Ed25519 signer for the Hermes iroh transport tests only — production
    // code is verify-only via Tink. Same lib + version the relay module's
    // test classpath uses.
    testImplementation("net.i2p.crypto:eddsa:0.3.0")
    // DataStore Preferences test helpers — the partner-save preference
    // store materialises a Preferences DataStore on a temp dir.
    testImplementation("androidx.datastore:datastore-preferences:1.2.1")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.compose.ui:ui-test-manifest")
    // Mockk on-device flavor — pure-JVM `io.mockk:mockk` brings in
    // bytebuddy classes the ART runtime can't load, so the instrumented
    // suites use `mockk-android` instead.
    androidTestImplementation("io.mockk:mockk-android:1.14.11")
}

detekt {
    config.setFrom(files("$projectDir/../detekt.yml"))
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
            to projectDir.resolve("src/main/java/com/openburnbar/ui/tokens/PensieveTokens.kt")
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

// syncGeneratedSources writes two files inside src/main/java, which the
// ktlint/detekt source scans and the dependency-analysis plugin's source
// exploders also read. Without an explicit ordering, Gradle 8 fails the
// build with an implicit-dependency validation error whenever scheduling
// happens to start a scan before the sync in the same invocation (surfaced
// when :macrobenchmark joined the task graph; again via
// :app:explodeCodeSourceBenchmarkRelease when projectHealth first ran).
tasks.matching {
    it.name.startsWith("runKtlintCheckOver") ||
        it.name.startsWith("runKtlintFormatOver") ||
        it.name.startsWith("explode") ||
        it is dev.detekt.gradle.Detekt
}.configureEach {
    mustRunAfter("syncGeneratedSources")
}

// Lint the Android Kotlin sources with ktlint. AGP 9 built-in Kotlin leaves
// `kotlin.sourceSets` empty, so ktlint-gradle only covers `.kts`; this shim
// restores enforcement over `src/**/*.kt`. See the script header for details.
apply(from = rootProject.file("gradle/ktlint-android-sources.gradle.kts"))
