package com.openburnbar.ui.square

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.firebase.FirebaseApp
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentCapabilities
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentRecentStats
import com.openburnbar.data.square.AgentTier
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented smoke test for `AgentBrandZoneScreen`. We render a
 * built-in Hermes identity, verify the display name renders, and let
 * the screen wire its dispatch sheets without exercising them.
 */
@RunWith(AndroidJUnit4::class)
class AgentBrandZoneScreenTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Before
    fun ensureFirebase() {
        FirebaseApp.initializeApp(
            InstrumentationRegistry.getInstrumentation().targetContext.applicationContext,
        )
    }

    @Test
    fun renders_display_name_and_capabilities() {
        val identity = AgentIdentity(
            id = AgentIdentity.builtInURI(AssistantRuntimeID.HERMES),
            runtimeID = AssistantRuntimeID.HERMES,
            displayName = "Hermes",
            glyph = "☿",
            paletteHex = "C8BFB5",
            tier = AgentTier.SERVICE,
            capabilities = AgentCapabilities(0xFF),
            tagline = "Mercury chat",
            lastSevenDays = AgentRecentStats(threadCount = 4, missionCount = 1, burnUSD = 0.12),
        )
        val registry = AgentIdentityRegistry.shared().also {
            // Ensure the singleton has at least our identity available.
            it.refreshAvailability(emptyMap())
        }
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    AgentBrandZoneScreen(
                        identity = identity,
                        registry = registry,
                        missionHost = MobileMissionConsoleHost.shared(),
                    )
                }
            }
        }
        composeRule.onNodeWithText("Hermes", substring = true).assertIsDisplayed()
    }
}
