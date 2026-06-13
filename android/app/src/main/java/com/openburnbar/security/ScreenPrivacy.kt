package com.openburnbar.security

import android.app.Activity
import android.view.WindowManager

/**
 * Blocks OS screenshots and recents thumbnails for BurnBar screens that can
 * expose prompts, transcripts, usage data, media sessions, or remote-control UI.
 */
fun Activity.enableOpenBurnBarScreenPrivacy() {
    window.setFlags(
        WindowManager.LayoutParams.FLAG_SECURE,
        WindowManager.LayoutParams.FLAG_SECURE,
    )
}
