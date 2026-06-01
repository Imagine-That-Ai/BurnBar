package com.openburnbar.ui.media

import android.graphics.Color as AndroidColor
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openburnbar.data.media.VideoReceivePipeline
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ScreenShareViewerDockTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun expandedDockGroupsControlsIntoCascadingShelves() {
        composeRule.setContent {
            MaterialTheme {
                var openGroup by remember { mutableStateOf<MirrorControlGroup?>(null) }
                Box(
                    modifier =
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black),
                ) {
                    ScreenMirrorToolsDock(
                        state =
                        MirrorDockUiState(
                            collapsed = false,
                            openGroup = openGroup,
                            fit = ScreenMirrorFit.FIT,
                            controlMode = ScreenMirrorControlMode.VIEW,
                            typingOpen = false,
                            statsVisible = false,
                            phaseLabel = "Live",
                            trayScale = 1f,
                            stats = VideoReceivePipeline.Stats(widthPx = 1920, heightPx = 1080),
                            availableDisplays = emptyList(),
                            activeDisplayId = null,
                            smartZoomMode = SmartZoomMode.SMART,
                            smartZoomAutoFollowing = false,
                            autoKeyboardOnTextFocus = false,
                            controlStatus = null,
                        ),
                        actions =
                        MirrorDockActions(
                            onSelectDisplay = {},
                            onTrayScaleChange = {},
                            onToggleCollapsed = {},
                            onSelectGroup = { openGroup = it },
                            onToggleStats = {},
                            onCycleFit = {},
                            onCycleControlMode = {},
                            onSelectSmartZoomMode = {},
                            onSelectControlMode = {},
                            onAutoKeyboardOnTextFocusChange = {},
                            onToggleTyping = {},
                            onScrollUp = {},
                            onScrollDown = {},
                            onEscape = {},
                            onCommandTab = {},
                            onPasteClipboardToMac = {},
                            onGrabClipboardFromMac = {},
                            onPanic = {},
                            onTrustControlDevice = {},
                            onReconnect = {},
                            onEnterPictureInPicture = {},
                            onClose = {},
                        ),
                    )
                }
            }
        }

        // Primary dock shows one keycap per group plus pinned collapse/close.
        listOf(
            "Mode",
            "Zoom",
            "Scroll",
            "Keys",
            "Screen",
            "Collapse mirror controls",
            "Close mirror",
        ).forEach { label ->
            composeRule.onNodeWithContentDescription(label).assertExists()
        }

        // Mode controls are shelved — hidden until the Mode group is opened.
        composeRule.onAllNodesWithContentDescription("Glass Trackpad mode").assertCountEquals(0)

        // No legacy single-letter keycaps.
        listOf("V", "T", "P", "S", "C").forEach { legacyLabel ->
            composeRule.onAllNodesWithText(legacyLabel).assertCountEquals(0)
        }

        // Opening the Mode group cascades the control-mode keycaps into view.
        composeRule.onNodeWithContentDescription("Mode").performClick()
        listOf(
            "View mode",
            "Click mode",
            "Glass Trackpad mode",
            "Scroll mode",
            "Agent Co-Pilot",
        ).forEach { label ->
            composeRule.onNodeWithContentDescription(label).assertExists()
        }

        val bitmap = composeRule.onRoot().captureToImage().asAndroidBitmap()
        var accentPixels = 0
        for (y in 0 until bitmap.height step 3) {
            for (x in 0 until bitmap.width step 3) {
                val pixel = bitmap.getPixel(x, y)
                val red = AndroidColor.red(pixel)
                val green = AndroidColor.green(pixel)
                val blue = AndroidColor.blue(pixel)
                val tealLike = green > red + 25 && blue > red + 20 && green > 45
                val violetLike = blue > red + 20 && blue > green + 15 && blue > 65
                if (tealLike || violetLike) {
                    accentPixels += 1
                }
            }
        }
        assertTrue(
            "Mirror dock should render visible iOS teal/violet gradient accents.",
            accentPixels > 40,
        )
    }
}
