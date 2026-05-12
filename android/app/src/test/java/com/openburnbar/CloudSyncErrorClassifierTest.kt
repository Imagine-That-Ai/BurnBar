package com.openburnbar

import com.openburnbar.data.stores.CloudSyncErrorClassifier
import com.openburnbar.data.stores.CloudSyncHealth
import org.junit.Assert.assertEquals
import org.junit.Test

class CloudSyncErrorClassifierTest {
    @Test
    fun `permission denied with app check language is app check blocked`() {
        assertEquals(
            CloudSyncHealth.APP_CHECK_BLOCKED,
            CloudSyncErrorClassifier.permissionDeniedHealth("Firebase App Check token is invalid.")
        )
    }

    @Test
    fun `rules permission denied remains permission denied`() {
        assertEquals(
            CloudSyncHealth.PERMISSION_DENIED,
            CloudSyncErrorClassifier.permissionDeniedHealth("Missing or insufficient permissions.")
        )
    }
}
