package com.openburnbar.data.media

import com.openburnbar.data.policy.MobileMercuryCapability
import com.openburnbar.data.policy.MobileMercuryMediaPolicy

/**
 * Thin "do I have a Mercury peer I can talk to right now" snapshot.
 * Mirrors `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryPeer.swift`.
 */
data class MercuryPeer(
    val connectionID: String,
    val displayName: String,
    val isOnline: Boolean,
    val lastSeenAtMillis: Long,
    val capabilities: Set<Feature>,
    val blurredWallpaperBase64: String? = null,
) {
    enum class Feature(val raw: String) {
        MIRROR_VIEWER(MobileMercuryCapability.MIRROR_VIEWER.raw),
        MIRROR_HOST(MobileMercuryCapability.MIRROR_HOST.raw),
        MIRROR_AUTO_ACCEPT(MobileMercuryCapability.MIRROR_AUTO_ACCEPT.raw),
        REMOTE_UNLOCK_HOST(MobileMercuryCapability.REMOTE_UNLOCK_HOST.raw),
        FILE_SEND(MobileMercuryCapability.FILE_SEND.raw),
        FILE_RECEIVE(MobileMercuryCapability.FILE_RECEIVE.raw),
        CALL_RECEIVE(MobileMercuryCapability.CALL_RECEIVE.raw),
        CALL_ORIGINATE(MobileMercuryCapability.CALL_ORIGINATE.raw),
        ;

        companion object {
            fun fromRaw(raw: String): Feature? = entries.firstOrNull { it.raw == raw }

            fun filterKnown(raw: Collection<String>): Set<Feature> =
                MobileMercuryMediaPolicy.filterCapabilities(raw).mapNotNull(::fromRaw).toSet()
        }
    }

    val canRequestMirror: Boolean
        get() = MobileMercuryMediaPolicy.canRequestMirror(isOnline, capabilities.map { it.raw })

    val canPlaceCall: Boolean
        get() = MobileMercuryMediaPolicy.canPlaceCall(isOnline, capabilities.map { it.raw })

    val canSendFile: Boolean
        get() = MobileMercuryMediaPolicy.canSendFile(isOnline, capabilities.map { it.raw })

    companion object {
        val macFallbackCapabilities: Set<Feature> = setOf(
            Feature.MIRROR_HOST,
            Feature.FILE_SEND,
            Feature.FILE_RECEIVE,
            Feature.CALL_RECEIVE,
        )

        val iphoneFallbackCapabilities: Set<Feature> = setOf(
            Feature.MIRROR_VIEWER,
            Feature.FILE_SEND,
            Feature.FILE_RECEIVE,
            Feature.CALL_RECEIVE,
        )
    }
}
