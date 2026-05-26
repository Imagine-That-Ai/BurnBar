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
    fun expandedDockUsesSemanticIconsInsteadOfLetterKeycaps() {
        composeRule.setContent {
            MaterialTheme {
                var customizeOpen by remember { mutableStateOf(false) }
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black),
                ) {
                    ScreenMirrorToolsDock(
                        collapsed = false,
                        customizeOpen = customizeOpen,
                        fit = ScreenMirrorFit.FIT,
                        controlMode = ScreenMirrorControlMode.VIEW,
                        typingOpen = false,
                        statsVisible = false,
                        phaseLabel = "Live",
                        trayScale = 1f,
                        stats = VideoReceivePipeline.Stats(widthPx = 1920, heightPx = 1080),
                        availableDisplays = emptyList(),
                        activeDisplayId = null,
                        onSelectDisplay = {},
                        onTrayScaleChange = {},
                        onToggleCollapsed = {},
                        onToggleCustomize = { customizeOpen = !customizeOpen },
                        onToggleStats = {},
                        onCycleFit = {},
                        onCycleControlMode = {},
                        smartZoomMode = SmartZoomMode.SMART,
                        smartZoomAutoFollowing = false,
                        onSelectSmartZoomMode = {},
                        onSelectControlMode = {},
                        onToggleTyping = {},
                        onScrollUp = {},
                        onScrollDown = {},
                        onEscape = {},
                        onCommandTab = {},
                        onPasteClipboardToMac = {},
                        onGrabClipboardFromMac = {},
                        onPanic = {},
                        controlStatus = null,
                        onTrustControlDevice = {},
                        onReconnect = {},
                        onEnterPictureInPicture = {},
                        onClose = {},
                    )
                }
            }
        }

        listOf(
            "View mode",
            "Click mode",
            "Glass Trackpad mode",
            "Scroll mode",
            "Agent Co-Pilot",
            "Show detailed controls",
        ).forEach { label ->
            composeRule.onNodeWithContentDescription(label).assertExists()
        }

        listOf("View", "Click", "Trackpad", "Scroll", "Co-Pilot", "Details").forEach { label ->
            composeRule.onAllNodesWithText(label).assertCountEquals(1)
        }

        listOf("V", "T", "P", "S", "C").forEach { legacyLabel ->
            composeRule.onAllNodesWithText(legacyLabel).assertCountEquals(0)
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

        composeRule.onNodeWithContentDescription("Show detailed controls").performClick()
        composeRule.onNodeWithContentDescription("Hide detailed controls").assertExists()
        composeRule.onAllNodesWithText("Detailed controls").assertCountEquals(1)
    }
}
