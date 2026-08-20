package com.openburnbar.ui.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * ACTION_SEND is an Activity. Copy the grantor URI into a contained inbox
 * path off the main thread, then enqueue unique WorkManager work. WorkManager
 * is the only begin() owner (KEEP); process start only re-enqueues leftovers.
 */
class BurnbarShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = intent?.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
        if (uri == null) {
            finish()
            return
        }
        lifecycleScope.launch {
            val dest =
                withContext(Dispatchers.IO) {
                    val inbox = BurnbarShareInboxProcessor.inboxDirectory(this@BurnbarShareActivity)
                    val dest = BurnbarShareInboxProcessor.containedDest(
                        inbox,
                        uri.lastPathSegment ?: "file",
                    )
                    contentResolver.openInputStream(uri)?.use { input ->
                        dest.outputStream().use { output -> input.copyTo(output) }
                    }
                    dest.takeIf { it.isFile && it.length() > 0 }
                }
            if (dest != null) {
                BurnbarShareInboxProcessor.enqueueUnique(applicationContext, dest)
            }
            finish()
        }
    }
}
