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
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented smoke test for the Hermes Square root screen. Verifies
 * that the screen composes without throwing once Firebase is
 * initialised — the runtime mission host + iroh pairing stores all
 * resolve their singletons inside the composable.
 */
@RunWith(AndroidJUnit4::class)
class HermesSquareScreenTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Before
    fun ensureFirebase() {
        FirebaseApp.initializeApp(
            InstrumentationRegistry.getInstrumentation().targetContext.applicationContext,
        )
    }

    @Test
    fun renders_top_app_bar_title() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesSquareScreen()
                }
            }
        }
        composeRule.onNodeWithText("Hermes Square", substring = true).assertIsDisplayed()
    }
}
