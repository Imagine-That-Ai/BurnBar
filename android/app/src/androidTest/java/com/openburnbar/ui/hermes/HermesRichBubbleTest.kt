package com.openburnbar.ui.hermes

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HermesRichBubbleTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun plain_prose_renders_unchanged() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesRichBubble(text = "Hello from Hermes.")
                }
            }
        }
        composeRule.onNodeWithText("Hello from Hermes.", substring = true).assertIsDisplayed()
    }

    @Test
    fun streaming_path_uses_plain_text() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesRichBubble(
                        text = "Streaming `code`",
                        isStreaming = true,
                    )
                }
            }
        }
        // While streaming we render plain text — backtick should appear
        // literally instead of being collapsed into a code span.
        composeRule.onNodeWithText("Streaming `code`", substring = true).assertIsDisplayed()
    }

    @Test
    fun mention_and_inline_code_render_in_one_pass() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesRichBubble(
                        text = "Ping @alberto about `rebase --autosquash` tomorrow.",
                    )
                }
            }
        }
        composeRule.onNodeWithText("@alberto", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("rebase --autosquash", substring = true).assertIsDisplayed()
    }
}
