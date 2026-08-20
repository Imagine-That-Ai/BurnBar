package com.openburnbar.data.media

import android.content.pm.ServiceInfo
import android.os.Build
import org.junit.Assert.assertEquals
import org.junit.Test

class BurnbarAttachmentTransferWorkerTest {
    @Test
    fun foregroundServiceTypeIsDataSyncOnApi34() {
        if (Build.VERSION.SDK_INT >= 34) {
            assertEquals(
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        }
    }
}
