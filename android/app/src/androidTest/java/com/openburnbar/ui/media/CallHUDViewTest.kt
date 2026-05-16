package com.openburnbar.ui.media

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented smoke test for the in-call HUD. The HUD has no
 * Firestore / IPC dependency — we drive it directly with a
 * `CallHUDState` instance and verify the formatted timer shows up.
 */
@RunWith(AndroidJUnit4::class)
class CallHUDViewTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun shows_formatted_duration() {
        val state = CallHUDState().apply { updateDuration("00:42") }

        composeRule.setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    CallHUDView(
                        state = state,
                        onMuteMic = {},
                        onMuteCamera = {},
                        onShareScreen = {},
                        onEnd = {},
                    )
                }
            }
        }
        composeRule.onNodeWithText("00:42", substring = true).assertIsDisplayed()
    }

    @Test
    fun renders_when_state_is_default() {
        val state = CallHUDState()
        composeRule.setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    CallHUDView(
                        state = state,
                        onMuteMic = {},
                        onMuteCamera = {},
                        onShareScreen = {},
                        onEnd = {},
                    )
                }
            }
        }
        // Default `formattedDuration` is "00:00"; the HUD should paint
        // even before the call session updates it.
        composeRule.onNodeWithText("00:00", substring = true).assertIsDisplayed()
    }
}
