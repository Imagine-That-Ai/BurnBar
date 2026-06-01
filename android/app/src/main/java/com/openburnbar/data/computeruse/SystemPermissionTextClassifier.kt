package com.openburnbar.data.computeruse

/**
 * Phase 14 — Heuristic classifier port. Same anchors as
 * `SystemPermissionToolFailureClassifier` on iOS so the Android phone
 * surfaces an inline pill when the Mac side never gets a chance to
 * report the bucket.
 */
object SystemPermissionTextClassifier {
    data class Match(
        val kind: PhoneControlSystemPermissionKind,
        val bundleId: String? = null,
        val category: String,
    )

    fun classifyToolResult(body: String): Match? = classify(body)

    fun classifyAssistantText(text: String): Match? {
        val lowered = text.lowercase()
        if (!SystemPermissionTextClassifierMatchers.containsPermissionTrigger(lowered)) return null
        return classify(text)
    }

    private fun classify(raw: String): Match? {
        val body = raw.lowercase()
        val automationBundle = SystemPermissionTextClassifierMatchers.automationBundleId(body)
        val mentionsAppleEvents = body.contains("apple events")
        val genericAutomation =
            body.contains("not allowed to send apple events") ||
                body.contains("not authorized to send apple events") ||
                body.contains("-1743") ||
                mentionsAppleEvents && body.contains("not permitted")
        return when {
            SystemPermissionTextClassifierMatchers.matchesScreenRecording(body) ->
                Match(PhoneControlSystemPermissionKind.SCREEN_RECORDING, null, "tccd_screen_recording")
            SystemPermissionTextClassifierMatchers.matchesAccessibility(body) ->
                Match(PhoneControlSystemPermissionKind.ACCESSIBILITY, null, "ax_trust")
            automationBundle != null ->
                Match(PhoneControlSystemPermissionKind.AUTOMATION, automationBundle, "apple_events")
            genericAutomation ->
                Match(PhoneControlSystemPermissionKind.AUTOMATION, null, "apple_events")
            SystemPermissionTextClassifierMatchers.matchesMicrophone(body) ->
                Match(PhoneControlSystemPermissionKind.MICROPHONE, null, "av_audio")
            SystemPermissionTextClassifierMatchers.matchesCamera(body) ->
                Match(PhoneControlSystemPermissionKind.CAMERA, null, "av_video")
            SystemPermissionTextClassifierMatchers.matchesFullDiskAccess(body) ->
                Match(PhoneControlSystemPermissionKind.FULL_DISK_ACCESS, null, "sandbox_fda")
            else -> null
        }
    }
}
