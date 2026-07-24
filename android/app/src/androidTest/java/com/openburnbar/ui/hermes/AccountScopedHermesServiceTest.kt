package com.openburnbar.ui.hermes

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AccountScopedHermesServiceTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun composedShellReplacesAndDisposesResourcesOnDirectAccountChange() {
        var accountUid by mutableStateOf("uid-a")
        val created = mutableListOf<FakeResource>()
        val disposed = mutableListOf<FakeResource>()
        val create: (String) -> FakeResource = { uid -> FakeResource(uid).also(created::add) }
        val dispose: (FakeResource) -> Unit = disposed::add

        composeRule.setContent {
            AccountScopedHermesServiceProvider(accountUid = accountUid) {
                rememberAccountScopedResource(create = create, dispose = dispose)
            }
        }
        composeRule.runOnIdle {
            assertEquals(listOf("uid-a"), created.map { it.uid })
            assertEquals(emptyList<FakeResource>(), disposed)
            accountUid = "uid-b"
        }
        composeRule.runOnIdle {
            assertEquals(listOf("uid-a", "uid-b"), created.map { it.uid })
            assertEquals(listOf("uid-a"), disposed.map { it.uid })
        }
    }

    private data class FakeResource(val uid: String)
}
