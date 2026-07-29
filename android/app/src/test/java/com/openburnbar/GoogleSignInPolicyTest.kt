package com.openburnbar

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GoogleSignInPolicyTest {
    @Test
    fun `credential manager is the only google sign-in path`() {
        val userStore = repoFile("android/app/src/main/java/com/openburnbar/data/stores/UserStore.kt").readText()
        val loginScreen = repoFile("android/app/src/main/java/com/openburnbar/ui/auth/LoginScreenSections.kt").readText()
        val appGradle = repoFile("android/app/build.gradle.kts").readText()

        assertTrue(userStore.contains("GetSignInWithGoogleOption.Builder(serverClientId)"))
        assertTrue(userStore.contains("catch (_: NoCredentialException)"))

        listOf(
            "GoogleSignIn",
            "GoogleSignInOptions",
            "GetGoogleIdOption",
            "needsLegacyGoogleFallback",
            "getGoogleSignInIntent",
            "handleGoogleSignInResult",
        ).forEach { forbidden ->
            assertFalse("Legacy Google sign-in symbol remains: $forbidden", userStore.contains(forbidden))
        }

        assertFalse(loginScreen.contains("rememberLauncherForActivityResult"))
        assertFalse(appGradle.contains("implementation(\"com.google.android.gms:play-services-auth"))
    }

    @Test
    fun `github sign-in icon uses the adaptive foreground color`() {
        val loginScreen = repoFile("android/app/src/main/java/com/openburnbar/ui/auth/LoginScreenSections.kt").readText()
        val githubButton =
            loginScreen
                .substringAfter("private fun GitHubButton")
                .substringBefore("@Composable\nprivate fun GoogleButton")

        assertTrue(githubButton.contains("R.drawable.github_logo"))
        assertTrue(githubButton.contains("ColorFilter.tint(textPrimary)"))
    }

    private fun repoFile(relativePath: String): File {
        val workingDirectory = System.getProperty("user.dir").orEmpty().ifBlank { "." }
        val start = File(workingDirectory).canonicalFile
        return generateSequence(start) { it.parentFile }
            .map { File(it, relativePath) }
            .firstOrNull(File::isFile)
            ?: error("Unable to locate $relativePath from $start")
    }
}
