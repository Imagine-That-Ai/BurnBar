// ── ktlint enforcement for Android Kotlin sources ───────────────────────────
// ktlint-gradle 12.3.0 wires its per-source-set check/format tasks from
// `kotlin.sourceSets`. Under AGP 9's *built-in Kotlin* that container is empty
// (the Android source sets live under the `android` extension instead), so the
// plugin silently lints only `.kts` build scripts — never `src/**/*.kt`. That
// gap is why this module carried a ~12k/2k-entry ktlint `baseline.xml` that
// suppressed nothing: ktlint never actually scanned the Kotlin sources.
//
// This script restores real enforcement by driving the *same* ktlint engine the
// plugin already resolves (`com.pinterest.ktlint:ktlint-cli`, pinned to the
// plugin's 1.0.1) over the Android Kotlin source dirs via JavaExec, and hooks
// the result into the canonical `ktlintCheck` / `ktlintFormat` lifecycle tasks —
// so CI's `./gradlew ktlintCheck` and `:app:ktlintCheck` now cover Kotlin source.
// ktlint reads each module's `.editorconfig`, so sources excluded there
// (UniFFI bindings, schema-sync / data-domains / design-token generated output)
// report clean without being reformatted.
//
// When ktlint-gradle (or AGP) gains built-in-Kotlin source-set discovery, this
// shim can be deleted in favour of the plugin's native tasks.

val ktlintCliVersion = "1.0.1"

val ktlintCli =
    configurations.create("ktlintCli") {
        isCanBeConsumed = false
        isCanBeResolved = true
    }

dependencies {
    add("ktlintCli", "com.pinterest.ktlint:ktlint-cli:$ktlintCliVersion")
}

// Only the source roots this module actually has; ktlint warns (harmlessly) on a
// glob that matches nothing, but filtering keeps the console clean.
val androidKotlinSourceGlobs =
    listOf(
        "src/main/java",
        "src/main/kotlin",
        "src/test/java",
        "src/test/kotlin",
        "src/androidTest/java",
        "src/androidTest/kotlin",
    ).filter { layout.projectDirectory.dir(it).asFile.exists() }
        .map { "$it/**/*.kt" }

// Resolve the globs to a concrete file set, used as a self-check below. ktlint
// gets the globs (not this list) so it still applies `.editorconfig` exclusions.
val androidKotlinSources = fileTree(layout.projectDirectory).matching { include(androidKotlinSourceGlobs) }

val ktlintAndroidSourceCheck =
    tasks.register<JavaExec>("ktlintAndroidSourceCheck") {
        group = "verification"
        description =
            "Runs ktlint over the Android Kotlin sources (AGP built-in Kotlin is not covered by ktlint-gradle's source-set tasks)."
        classpath = ktlintCli
        mainClass.set("com.pinterest.ktlint.Main")
        // Pin the working dir to the project dir so ktlint's globs and the guard's
        // file tree below resolve against the same root (no divergence).
        workingDir = layout.projectDirectory.asFile
        // ktlint exits non-zero on any violation, which fails the build.
        args(listOf("--relative") + androidKotlinSourceGlobs)
        // Anti-vacuous-pass guard: a Kotlin source set that resolves to ZERO files
        // is exactly how ktlint went silently inert under AGP built-in Kotlin (it
        // "passed" because it scanned nothing). Fail loudly instead, and log the
        // count so CI carries positive evidence that enforcement actually ran.
        doFirst {
            val count = androidKotlinSources.files.size
            if (count == 0) {
                error(
                    "ktlint resolved 0 Kotlin source files in ${project.path} -- enforcement is silently " +
                        "off. Re-check the source globs / AGP source-set wiring in " +
                        "gradle/ktlint-android-sources.gradle.kts.",
                )
            }
            logger.lifecycle("ktlint: linting $count Kotlin source files in ${project.path}")
        }
    }

val ktlintAndroidSourceFormat =
    tasks.register<JavaExec>("ktlintAndroidSourceFormat") {
        group = "formatting"
        description = "Formats the Android Kotlin sources with ktlint."
        classpath = ktlintCli
        mainClass.set("com.pinterest.ktlint.Main")
        workingDir = layout.projectDirectory.asFile
        args(listOf("--format", "--relative") + androidKotlinSourceGlobs)
        // Non-autofixable violations remaining after a format pass must not fail a
        // developer's local `ktlintFormat`; CI enforcement is the check task.
        isIgnoreExitValue = true
    }

tasks.named("ktlintCheck") { dependsOn(ktlintAndroidSourceCheck) }

tasks.named("ktlintFormat") { dependsOn(ktlintAndroidSourceFormat) }

// In :app, `syncGeneratedSources` materializes generated Kotlin into
// src/main/java; order ktlint after it so a fresh tree is linted. (Those files
// are ktlint-excluded via .editorconfig, so this is for cleanliness, not
// correctness.) No-op in modules without that task.
listOf(ktlintAndroidSourceCheck, ktlintAndroidSourceFormat).forEach { provider ->
    provider.configure { mustRunAfter(tasks.matching { it.name == "syncGeneratedSources" }) }
}
