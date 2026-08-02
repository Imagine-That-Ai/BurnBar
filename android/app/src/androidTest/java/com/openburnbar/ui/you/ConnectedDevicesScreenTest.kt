package com.openburnbar.ui.you

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openburnbar.data.stores.DeviceRecord
import com.openburnbar.data.stores.DeviceTrustState
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConnectedDevicesScreenTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun pendingDeviceRequiresSafetyConfirmationBeforeApproval() {
        val approved = mutableListOf<String>()
        val pending =
            DeviceRecord(
                id = "pending-ipad",
                escrowID = "pending-ipad",
                displayName = "Alberto's iPad",
                platform = "iPadOS",
                trustState = DeviceTrustState.PENDING,
                publicKeyFingerprint = FINGERPRINT_BASE64,
                publicKeyData = PUBLIC_KEY_BASE64,
            )
        composeRule.setContent {
            MaterialTheme {
                ConnectedDevicesContent(
                    devices =
                    listOf(
                        DeviceRecord(
                            id = "samsung-current",
                            displayName = "Samsung Galaxy",
                            platform = "Android",
                            trustState = DeviceTrustState.TRUSTED,
                            isCurrentDevice = true,
                        ),
                        pending,
                    ),
                    isLoading = false,
                    lastError = null,
                    actionInFlightFor = null,
                    bootstrapEligible = false,
                    staleDuplicateCount = 0,
                    onBack = {},
                    onRefresh = {},
                    onBootstrapApproveSelf = {},
                    onRenameSelf = {},
                    onApprove = { approved += it.id },
                    onRevoke = {},
                    onCleanupDuplicates = {},
                )
            }
        }

        composeRule
            .onNodeWithTag("connectedDevices.approve.pending-ipad")
            .performScrollTo()
            .assertIsEnabled()
            .performClick()
        composeRule.onNodeWithTag("connectedDevices.approve.compared").performClick()
        composeRule
            .onNodeWithTag("connectedDevices.approve.confirm")
            .assertIsEnabled()
            .performClick()

        composeRule.runOnIdle {
            assertEquals(listOf("pending-ipad"), approved)
        }
    }

    private companion object {
        const val PUBLIC_KEY_BASE64 =
            "BF8kD8cxysQZYfK+E5P47VMA2Kyf7qQ8SSJh0QB3RkparBtbyeL7XrAue1wanXNo0KUc5OzpAtUWp6oWSYrKzfM="
        const val FINGERPRINT_BASE64 = "gpX18YwBJijSAfecJvCp7Fmc5wM+uzmwJxbbGcoGoAw="
    }
}
