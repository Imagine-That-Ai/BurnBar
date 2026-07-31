package com.openburnbar.ui.media

import com.openburnbar.data.media.MediaControlStreamCoordinator

/**
 * Keeps a mirror bound to the current Mercury control stream without
 * disturbing the freshly accepted stream during the viewer's first resume.
 *
 * Launching the viewer immediately follows a mirror acknowledgement. Probing
 * that new stream during the first Activity resume can race ScreenCaptureKit
 * startup on the Mac and incorrectly recycle a healthy stream. Later resumes
 * still run the responsiveness probe. If the coordinator actually reconnects,
 * the accepted mirror request belongs to the old stream, so the viewer mints
 * one replacement request after the new stream reaches Live.
 */
internal class ScreenShareViewerConnectionRecovery {
    private var consumedInitialResume = false
    private var awaitingMirrorRebind = false

    fun shouldProbeOnResume(): Boolean {
        if (!consumedInitialResume) {
            consumedInitialResume = true
            return false
        }
        return true
    }

    fun shouldRebindMirror(phase: MediaControlStreamCoordinator.Phase, hasActiveMirrorRequest: Boolean): Boolean {
        if (!hasActiveMirrorRequest) {
            awaitingMirrorRebind = false
            return false
        }

        when (phase) {
            MediaControlStreamCoordinator.Phase.Dialing,
            is MediaControlStreamCoordinator.Phase.Reconnecting,
            is MediaControlStreamCoordinator.Phase.Failed,
            -> awaitingMirrorRebind = true

            MediaControlStreamCoordinator.Phase.Live -> {
                if (awaitingMirrorRebind) {
                    awaitingMirrorRebind = false
                    return true
                }
            }

            MediaControlStreamCoordinator.Phase.Idle,
            MediaControlStreamCoordinator.Phase.Stopped,
            -> Unit
        }
        return false
    }
}
