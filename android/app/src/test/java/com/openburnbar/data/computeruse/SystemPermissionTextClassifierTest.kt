package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SystemPermissionTextClassifierTest {
    @Test
    fun classifiesScreenRecordingFailure() {
        val match =
            SystemPermissionTextClassifier.classifyToolResult(
                "screencapture: cannot grab the screen because Screen Recording permission is required",
            )
        assertEquals(PhoneControlSystemPermissionKind.SCREEN_RECORDING, match?.kind)
    }

    @Test
    fun classifiesAccessibilityFailure() {
        val match =
            SystemPermissionTextClassifier.classifyToolResult(
                "AXIsProcessTrusted returned false — accessibility permission is required",
            )
        assertEquals(PhoneControlSystemPermissionKind.ACCESSIBILITY, match?.kind)
    }

    @Test
    fun classifiesAutomationBundleId() {
        val match =
            SystemPermissionTextClassifier.classifyToolResult(
                "NSAppleScript: not allowed to send apple events to com.apple.Safari",
            )
        assertEquals(PhoneControlSystemPermissionKind.AUTOMATION, match?.kind)
        assertEquals("com.apple.safari", match?.bundleId)
    }

    @Test
    fun classifiesMicrophoneBeforeCamera() {
        val match =
            SystemPermissionTextClassifier.classifyToolResult(
                "AVCaptureDevice.audio: no permission to access the microphone",
            )
        assertEquals(PhoneControlSystemPermissionKind.MICROPHONE, match?.kind)
    }

    @Test
    fun ignoresPlainRefusal() {
        assertNull(
            SystemPermissionTextClassifier.classifyToolResult(
                "Sorry, I can't take a screenshot for you right now.",
            ),
        )
    }

    @Test
    fun assistantTextRequiresPermissionAnchor() {
        assertNull(SystemPermissionTextClassifier.classifyAssistantText("I cannot help with that"))
        val match =
            SystemPermissionTextClassifier.classifyAssistantText(
                "Screen Recording permission is required on your Mac.",
            )
        assertEquals(PhoneControlSystemPermissionKind.SCREEN_RECORDING, match?.kind)
    }
}
