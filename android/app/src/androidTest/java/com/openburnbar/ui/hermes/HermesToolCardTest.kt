package com.openburnbar.ui.hermes

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openburnbar.data.hermes.MobileTool
import com.openburnbar.data.hermes.MobileToolCategoryGroup
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HermesToolCardTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    private val ripgrep = MobileTool(
        id = "ripgrep",
        name = "ripgrep",
        description = "Search the repo for a pattern",
        icon = "Search",
        categoryGroup = MobileToolCategoryGroup.SEARCH,
    )

    @Test
    fun running_card_shows_status_text() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesToolCard(
                        tool = ripgrep,
                        state = ToolCardState.Running(statusText = "Scanning…"),
                    )
                }
            }
        }
        composeRule.onNodeWithText("ripgrep", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("Scanning", substring = true).assertIsDisplayed()
    }

    @Test
    fun done_card_collapses_to_single_line_then_expands_on_tap() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesToolCard(
                        tool = ripgrep,
                        state = ToolCardState.Done,
                        argumentsPreview = "{\"pattern\":\"HermesSquare\"}",
                        resultPreview = "5 matches in 3 files",
                    )
                }
            }
        }
        composeRule.onNodeWithText("ripgrep", substring = true).assertIsDisplayed()
        // Tap the tool card → progressive disclosure expands the
        // argument + result body.
        composeRule.onNodeWithText("ripgrep", substring = true).performClick()
        composeRule.onNodeWithText("HermesSquare", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("5 matches", substring = true).assertIsDisplayed()
    }

    @Test
    fun failed_card_shows_failure_message() {
        composeRule.setContent {
            MaterialTheme {
                Surface {
                    HermesToolCard(
                        tool = ripgrep,
                        state = ToolCardState.Failed("permission denied"),
                        initiallyExpanded = true,
                    )
                }
            }
        }
        composeRule.onNodeWithText("permission denied", substring = true).assertIsDisplayed()
    }
}
