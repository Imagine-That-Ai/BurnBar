package com.openburnbar.data.policy

enum class MobileMercuryCapability(val raw: String) {
    MIRROR_VIEWER("mirror.viewer"),
    MIRROR_HOST("mirror.host"),
    MIRROR_AUTO_ACCEPT("mirror.auto_accept"),
    REMOTE_UNLOCK_HOST("remote_unlock.host"),
    FILE_SEND("file.send"),
    FILE_RECEIVE("file.receive"),
    CALL_RECEIVE("call.receive"),
    CALL_ORIGINATE("call.originate"),
    ;

    companion object {
        fun fromRaw(raw: String): MobileMercuryCapability? = entries.firstOrNull { it.raw == raw }
    }
}

enum class MobileMercuryInviteAck(val wire: String) {
    PAIRED("paired"),
    MISMATCH("mismatch"),
    DENIED("denied"),
}

enum class MobileMercurySessionPresentation(val wire: String) {
    IDLE("idle"),
    CONNECTED("connected"),
    RECONNECTING("reconnecting"),
    DENIED("denied"),
    FAILED("failed"),
}

/** Mercury/media.control decisions. Source: iOS MercuryPeer + 60s heartbeat. */
object MobileMercuryMediaPolicy {
    const val HEARTBEAT_INTERVAL_MS: Long = 60_000L

    val phoneHeartbeatCapabilities: List<String> = listOf(
        MobileMercuryCapability.MIRROR_VIEWER.raw,
        MobileMercuryCapability.FILE_SEND.raw,
        MobileMercuryCapability.FILE_RECEIVE.raw,
        MobileMercuryCapability.CALL_RECEIVE.raw,
    )

    fun filterCapabilities(raw: Collection<String>): List<String> {
        val known = MobileMercuryCapability.entries.map { it.raw }.toSet()
        return raw.filter { known.contains(it) }.toSet().sorted()
    }

    fun inviteAckPair(inviteId: String, ackId: String, accepted: Boolean): MobileMercuryInviteAck {
        if (inviteId.trim().isEmpty() || ackId.trim().isEmpty() || inviteId != ackId) {
            return MobileMercuryInviteAck.MISMATCH
        }
        return if (accepted) MobileMercuryInviteAck.PAIRED else MobileMercuryInviteAck.DENIED
    }

    fun sessionPresentation(phase: String, denied: Boolean): MobileMercurySessionPresentation {
        if (denied) return MobileMercurySessionPresentation.DENIED
        return when (phase) {
            "live" -> MobileMercurySessionPresentation.CONNECTED
            "reconnecting" -> MobileMercurySessionPresentation.RECONNECTING
            "failed" -> MobileMercurySessionPresentation.FAILED
            else -> MobileMercurySessionPresentation.IDLE
        }
    }

    fun canRequestMirror(isOnline: Boolean, capabilities: Collection<String>): Boolean =
        isOnline && capabilities.contains(MobileMercuryCapability.MIRROR_HOST.raw)

    fun canPlaceCall(isOnline: Boolean, capabilities: Collection<String>): Boolean = isOnline && capabilities.contains(MobileMercuryCapability.CALL_RECEIVE.raw)

    fun canSendFile(isOnline: Boolean, capabilities: Collection<String>): Boolean = isOnline && capabilities.contains(MobileMercuryCapability.FILE_RECEIVE.raw)
}
