package com.openburnbar.data.policy

/** Spoken labels shared by Pulse/Burn/Hermes/Inbox. */
object MobileAccessibilityLabelPolicy {
    fun heroBurn(displayMode: String, heroText: String, liveRate: String?): String {
        val parts = mutableListOf("Hero burn", displayMode, heroText)
        if (!liveRate.isNullOrBlank()) parts.add("live rate $liveRate")
        return parts.joinToString(", ")
    }

    fun quotaPercentRemaining(fraction: Double): Int = kotlin.math.round(fraction * 100.0).toInt()

    fun quotaRing(label: String, percentRemaining: Int): String =
        "$label, $percentRemaining percent remaining"

    fun quotaRing(label: String, remainingFraction: Double): String =
        quotaRing(label, quotaPercentRemaining(remainingFraction))

    fun chart(label: String, summary: String): String = "$label, $summary"

    fun iconOnly(action: String): String = action

    fun loading(surface: String): String = "$surface loading"

    fun error(surface: String): String = "$surface failed to load"

    fun liveStream(surface: String): String = "$surface live"

    fun stopButton(isStreaming: Boolean): String =
        if (isStreaming) "Stop generating" else "Send"

    fun inboxRow(
        unread: Boolean,
        kindLabel: String,
        priorityLabel: String?,
        title: String,
    ): String {
        val parts = mutableListOf<String>()
        if (unread) parts.add("Unread")
        parts.add(kindLabel)
        if (!priorityLabel.isNullOrEmpty()) parts.add(priorityLabel)
        parts.add(title)
        return parts.joinToString(", ")
    }
}
