package com.openburnbar.data.support

import com.openburnbar.data.models.AndroidDiagnosticsSnapshot
import com.openburnbar.data.models.BugReportSubmission
import com.openburnbar.data.models.BugReportSubmissionResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BugReportServiceTest {
    @Test
    fun `BugReportSubmission creates expected data model`() {
        val submission =
            BugReportSubmission(
                title = "[Bug] Crash on settings tap",
                description = "Settings tab threw null pointer exception",
                platform = "Android",
                appVersion = "1.2.0",
                osVersion = "Android 14 (API 34)",
                deviceModel = "Google Pixel 8",
                diagnostics = mapOf("battery" to "95%"),
                autoDispenseCLI = true,
                requestedRuntime = "claude",
            )

        assertEquals("[Bug] Crash on settings tap", submission.title)
        assertEquals("Settings tab threw null pointer exception", submission.description)
        assertEquals("Android", submission.platform)
        assertEquals("1.2.0", submission.appVersion)
        assertEquals("Android 14 (API 34)", submission.osVersion)
        assertEquals("Google Pixel 8", submission.deviceModel)
        assertTrue(submission.autoDispenseCLI)
        assertEquals("claude", submission.requestedRuntime)
    }

    @Test
    fun `BugReportSubmissionResult stores linear issue and missionId`() {
        val result =
            BugReportSubmissionResult(
                reportId = "rep_abc123",
                linearIdentifier = "BB-88",
                linearUrl = "https://linear.app/openburnbar/issue/BB-88",
                isMock = false,
                missionId = "mission_bug_rep_abc123",
            )

        assertEquals("rep_abc123", result.reportId)
        assertEquals("BB-88", result.linearIdentifier)
        assertEquals("https://linear.app/openburnbar/issue/BB-88", result.linearUrl)
        assertFalse(result.isMock)
        assertEquals("mission_bug_rep_abc123", result.missionId)
    }

    @Test
    fun `AndroidDiagnosticsSnapshot converts to non-empty map`() {
        val snapshot =
            AndroidDiagnosticsSnapshot(
                osVersion = "Android 14",
                deviceModel = "Pixel 8",
                appVersion = "1.0.0",
                appBuild = "42",
                board = "shiba",
                timestamp = "1234567890",
            )

        val map = snapshot.toMap()
        assertEquals("Android 14", map["osVersion"])
        assertEquals("Pixel 8", map["deviceModel"])
        assertEquals("1.0.0", map["appVersion"])
        assertEquals("42", map["appBuild"])
        assertEquals("shiba", map["board"])
        assertEquals("1234567890", map["timestamp"])
    }

    @Test
    fun `callablePayload includes optional fields and diagnostics`() {
        val submission =
            BugReportSubmission(
                title = "[Bug] Crash on settings tap",
                description = "Settings tab threw null pointer exception",
                platform = "Android",
                appVersion = "1.2.0",
                osVersion = "Android 14 (API 34)",
                deviceModel = "Google Pixel 8",
                diagnostics = mapOf("battery" to "95%"),
                logsSnippet = "stack",
                autoDispenseCLI = false,
                requestedRuntime = "claude",
                targetProject = "BurnBar",
            )

        val payload = BugReportService.callablePayload(submission)
        assertEquals("[Bug] Crash on settings tap", payload["title"])
        assertEquals("Android", payload["platform"])
        assertEquals(false, payload["autoDispenseCLI"])
        assertEquals("1.2.0", payload["appVersion"])
        assertEquals("stack", payload["logsSnippet"])
        assertEquals("claude", payload["requestedRuntime"])
        assertEquals("BurnBar", payload["targetProject"])
        val diagnostics = payload["diagnostics"]
        require(diagnostics is Map<*, *>) { "diagnostics should be a string map" }
        assertEquals("95%", diagnostics["battery"])
    }

    @Test
    fun `callablePayload omits optional fields when they are absent`() {
        val payload =
            BugReportService.callablePayload(
                BugReportSubmission(
                    title = "[Bug] Minimal",
                    description = "No extras",
                    platform = "Android",
                    autoDispenseCLI = true,
                ),
            )

        assertEquals("[Bug] Minimal", payload["title"])
        assertEquals("Android", payload["platform"])
        assertEquals(true, payload["autoDispenseCLI"])
        assertFalse(payload.containsKey("appVersion"))
        assertFalse(payload.containsKey("diagnostics"))
        assertFalse(payload.containsKey("logsSnippet"))
        assertFalse(payload.containsKey("requestedRuntime"))
        assertFalse(payload.containsKey("targetProject"))
    }

    @Test
    fun `parseSubmissionResult maps linear issue and missionId`() {
        val result =
            BugReportService.parseSubmissionResult(
                mapOf(
                    "reportId" to "rep_abc123",
                    "missionId" to "mission_bug_rep_abc123",
                    "linearIssue" to mapOf(
                        "identifier" to "BB-88",
                        "url" to "https://linear.app/openburnbar/issue/BB-88",
                        "mock" to false,
                    ),
                ),
            )

        assertEquals("rep_abc123", result.reportId)
        assertEquals("BB-88", result.linearIdentifier)
        assertEquals("https://linear.app/openburnbar/issue/BB-88", result.linearUrl)
        assertFalse(result.isMock)
        assertEquals("mission_bug_rep_abc123", result.missionId)
    }

    @Test
    fun `parseSubmissionResult uses defaults when linear issue is missing`() {
        val result = BugReportService.parseSubmissionResult(mapOf("reportId" to "rep_1"))
        assertEquals("rep_1", result.reportId)
        assertEquals("BB-ISSUE", result.linearIdentifier)
        assertEquals("https://linear.app", result.linearUrl)
        assertFalse(result.isMock)
        assertEquals(null, result.missionId)
    }

    @Test
    fun `parseSubmissionResult rejects a non-map payload`() {
        try {
            BugReportService.parseSubmissionResult("nope")
            org.junit.Assert.fail("Expected invalid server payload to throw")
        } catch (error: IllegalStateException) {
            assertEquals("Invalid response from server.", error.message)
        }
    }
}
