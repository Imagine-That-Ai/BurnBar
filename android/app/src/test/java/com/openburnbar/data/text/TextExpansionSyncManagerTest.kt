package com.openburnbar.data.text

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.openburnbar.data.db.TextExpansionDao
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TextExpansionSyncManagerTest {
    private val context = mockk<Context>(relaxed = true)
    private val dao = mockk<TextExpansionDao>(relaxed = true)
    private val prefs = mockk<SharedPreferences>(relaxed = true)

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.d(any(), any()) } returns 0
        every { context.getSharedPreferences("text_expansion_settings", Context.MODE_PRIVATE) } returns prefs
    }

    @After
    fun tearDown() {
        unmockkStatic(Log::class)
    }

    @Test
    fun syncSkipsIfDisabledInSettings() = runBlocking {
        every { prefs.getBoolean("cloud_sync_enabled", true) } returns false

        val manager = TextExpansionSyncManager(context, dao, mockk(relaxed = true))
        val result = manager.sync()

        assertTrue(result.isSuccess)
        verify(exactly = 0) { dao.getUnsynced(any()) }
    }
}
