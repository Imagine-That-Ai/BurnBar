package com.openburnbar.data.media

/**
 * Receiver admission for GOP-tagged Mercury video on the muxed
 * `media.control` stream. 1:1 port of `MediaGOP.swift`.
 */
class MediaGOPReceiveWindow {
    enum class Decision {
        DECODE,
        DROP_STALE,
        DROP_UNANCHORED,
    }

    var activeGopID: UInt? = null
        private set
    var highestCompletedGopID: UInt? = null
        private set
    var abortedGopCount: Int = 0
        private set

    fun reset() {
        activeGopID = null
        highestCompletedGopID = null
        abortedGopCount = 0
    }

    fun admit(gopID: UInt, isKeyframe: Boolean, isEndOfGroup: Boolean): Decision {
        val completed = highestCompletedGopID
        if (completed != null && gopID < completed) return Decision.DROP_STALE

        if (isKeyframe) {
            val active = activeGopID
            if (active != null && gopID < active) return Decision.DROP_STALE
            if (active != null && gopID > active) {
                markCompleted(active)
            }
            activeGopID = gopID
            if (isEndOfGroup) markCompleted(gopID)
            return Decision.DECODE
        }

        val active = activeGopID ?: return Decision.DROP_UNANCHORED
        if (gopID < active) return Decision.DROP_STALE
        if (gopID > active) return Decision.DROP_UNANCHORED
        if (isEndOfGroup) markCompleted(gopID)
        return Decision.DECODE
    }

    private fun markCompleted(gopID: UInt) {
        val completed = highestCompletedGopID
        if (completed != null && gopID <= completed) return
        val active = activeGopID
        if (active != null && active < gopID) {
            abortedGopCount += 1
        }
        highestCompletedGopID = gopID
    }
}

/** One-frame hold that stamps `END_OF_GROUP` when the next GOP keyframe arrives. */
class MediaGOPEndStamper {
    private var held: MediaFrame? = null

    fun push(frame: MediaFrame): MediaFrame? {
        val previous = held
        if (previous == null) {
            held = frame
            return null
        }
        val stamped =
            if (MediaFrame.Flags.KEYFRAME in frame.flags && previous.gopID != frame.gopID) {
                previous.copy(flags = previous.flags.or(MediaFrame.Flags.END_OF_GROUP))
            } else {
                previous
            }
        held = frame
        return stamped
    }

    fun flush(): MediaFrame? {
        val last = held ?: return null
        held = null
        return last.copy(flags = last.flags.or(MediaFrame.Flags.END_OF_GROUP))
    }
}
