package com.openburnbar.data.media

/**
 * 1:1 Kotlin port of `MediaStreamClass` (Swift
 * `OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaStreamClass.swift`).
 *
 * Carried as a string newtype rather than an enum so unknown classes
 * route to a no-op handler instead of failing to decode. Phase numbers
 * mirror the master plan: file transfer is Phase 1, screen share Phase
 * 3, audio Phase 4, video Phase 5, Computer Use Phase 8+.
 */
@JvmInline
value class MediaStreamClass(val raw: String) {
    enum class Feature { FILE_TRANSFER, SCREEN_SHARE, VIDEO_CALL, COMPUTER_USE }

    val feature: Feature?
        get() = when (raw) {
            BLOB_ADVERTISE.raw, BLOB_FETCH.raw, BLOB.raw -> Feature.FILE_TRANSFER
            SCREEN_VIDEO.raw -> Feature.SCREEN_SHARE
            VIDEO_OUT.raw, VIDEO_IN.raw, AUDIO_OUT.raw, AUDIO_IN.raw -> Feature.VIDEO_CALL
            CONTROL_SURFACE_FRAME.raw, CONTROL_ACTION_LOG.raw, CONTROL_INPUT.raw, CONTROL_APPROVAL.raw -> Feature.COMPUTER_USE
            else -> null
        }

    fun isAvailable(asOfPhase: Int): Boolean = when (raw) {
        BLOB_ADVERTISE.raw, BLOB_FETCH.raw, BLOB.raw -> asOfPhase >= 1
        SCREEN_VIDEO.raw, CONTROL.raw, CLASSIFY.raw -> asOfPhase >= 3
        AUDIO_OUT.raw, AUDIO_IN.raw -> asOfPhase >= 4
        VIDEO_OUT.raw, VIDEO_IN.raw -> asOfPhase >= 5
        CONTROL_SURFACE_FRAME.raw, CONTROL_ACTION_LOG.raw, CONTROL_INPUT.raw, CONTROL_APPROVAL.raw -> asOfPhase >= 8
        else -> false
    }

    companion object {
        val BLOB_ADVERTISE = MediaStreamClass("media.blob.advertise")
        val BLOB_FETCH = MediaStreamClass("media.blob.fetch")
        val BLOB = MediaStreamClass("media.blob")
        val SCREEN_VIDEO = MediaStreamClass("media.screen.video")
        val AUDIO_OUT = MediaStreamClass("media.audio.out")
        val AUDIO_IN = MediaStreamClass("media.audio.in")
        val VIDEO_OUT = MediaStreamClass("media.video.out")
        val VIDEO_IN = MediaStreamClass("media.video.in")
        val CONTROL = MediaStreamClass("media.control")
        val CLASSIFY = MediaStreamClass("media.classify")
        val CONTROL_SURFACE_FRAME = MediaStreamClass("control.surface.frame")
        val CONTROL_ACTION_LOG = MediaStreamClass("control.action.log")
        val CONTROL_INPUT = MediaStreamClass("control.input")
        val CONTROL_APPROVAL = MediaStreamClass("control.approval")
    }
}
