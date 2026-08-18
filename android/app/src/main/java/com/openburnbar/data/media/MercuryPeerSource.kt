package com.openburnbar.data.media

import com.openburnbar.data.policy.MobileMercuryMediaPolicy
import com.openburnbar.data.policy.MobileMercurySessionPresentation

/**
 * Resolves a [MercuryPeer] from the media.control stream phase plus the
 * paired-Mac display name (Firestore / relay record).
 */
object MercuryPeerSource {
    fun resolve(
        connectionID: String?,
        displayName: String?,
        phase: MediaControlStreamCoordinator.Phase,
        lastSeenAtMillis: Long,
        heartbeatCapabilities: Collection<String>,
        denied: Boolean,
        nowMillis: Long = System.currentTimeMillis(),
    ): MercuryPeer? {
        val id = connectionID?.trim().orEmpty()
        if (id.isEmpty()) return null
        val presentation = MobileMercuryMediaPolicy.sessionPresentation(phaseToken(phase), denied)
        val isOnline = presentation == MobileMercurySessionPresentation.CONNECTED
        val parsed = MercuryPeer.Feature.filterKnown(heartbeatCapabilities)
        val capabilities = when {
            parsed.isNotEmpty() -> parsed
            heartbeatCapabilities.isEmpty() && isOnline -> MercuryPeer.macFallbackCapabilities
            else -> emptySet()
        }
        return MercuryPeer(
            connectionID = id,
            displayName = displayName?.trim()?.takeIf { it.isNotEmpty() } ?: "My Mac",
            isOnline = isOnline,
            lastSeenAtMillis = if (lastSeenAtMillis > 0L) lastSeenAtMillis else nowMillis,
            capabilities = capabilities,
        )
    }

    fun phaseToken(phase: MediaControlStreamCoordinator.Phase): String = when (phase) {
        is MediaControlStreamCoordinator.Phase.Live -> "live"
        is MediaControlStreamCoordinator.Phase.Reconnecting -> "reconnecting"
        is MediaControlStreamCoordinator.Phase.Failed -> "failed"
        else -> "idle"
    }
}
