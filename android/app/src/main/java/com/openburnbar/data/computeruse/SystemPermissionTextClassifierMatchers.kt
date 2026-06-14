package com.openburnbar.data.computeruse

internal object SystemPermissionTextClassifierMatchers {
    fun matchesScreenRecording(body: String): Boolean {
        val anchors = listOf("screen recording", "screen capture", "screencapturekit", "scstream", "cgdisplay")
        val denials = listOf("permission", "not allowed", "denied", "is required", "requires")
        val hasAnchorAndDenial = anchors.any { body.contains(it) } && denials.any { body.contains(it) }
        val screencaptureBlocked = body.contains("screencapture") && body.contains("cannot")
        return hasAnchorAndDenial || screencaptureBlocked
    }

    fun matchesAccessibility(body: String): Boolean = listOf(
        "axisprocesstrusted",
        "accessibility access",
        "accessibility permission",
        "accessibility is required",
        "not trusted to use accessibility",
        "kaxerrorpermission",
        "accessibility api",
    ).any { body.contains(it) }

    fun matchesMicrophone(body: String): Boolean = listOf(
        "microphone permission",
        "microphone access",
        "microphone is denied",
        "no permission to access the microphone",
        "audio capture is not allowed",
    ).any { body.contains(it) }

    fun matchesCamera(body: String): Boolean = listOf(
        "camera permission",
        "camera access",
        "camera is denied",
        "no permission to access the camera",
        "video capture is not allowed",
    ).any { body.contains(it) }

    fun matchesFullDiskAccess(body: String): Boolean {
        val pathHints = listOf("~/library/", "/library/safari", "/library/mail", "tcc.db")
        val phraseHints = listOf("full disk access", "fda", "full-disk access", "operation not permitted")
        return pathHints.any { body.contains(it) } && phraseHints.any { body.contains(it) }
    }

    fun automationBundleId(body: String): String? {
        val mentionsAutomation =
            body.contains("apple events") ||
                body.contains("automation") ||
                body.contains("scripting bridge")
        if (!mentionsAutomation) return null
        val regex = Regex("(com|app|org)\\.[a-z0-9_\\-\\.]+")
        val match = regex.find(body) ?: return null
        return match.value.trim('.', ',', ';', ':', ')', '"')
    }

    fun containsPermissionTrigger(body: String): Boolean = listOf(
        "permission",
        "not allowed",
        "denied",
        "is required",
        "requires",
        "system settings",
        "privacy & security",
        "privacy and security",
    ).any { body.contains(it) }
}
