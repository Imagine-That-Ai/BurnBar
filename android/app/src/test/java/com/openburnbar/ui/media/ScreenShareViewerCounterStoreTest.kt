package com.openburnbar.ui.media

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Test

class ScreenShareViewerCounterStoreTest {
    @Test
    fun `production counter store survives viewer recreation`() {
        val persisted = AtomicLong(88)
        val preferences = mockk<SharedPreferences>()
        every { preferences.getLong(any(), any()) } answers { persisted.get() }
        every { preferences.edit() } answers {
            val editor = mockk<SharedPreferences.Editor>()
            var pending = 0L
            every { editor.putLong(any(), any()) } answers {
                pending = secondArg()
                editor
            }
            every { editor.commit() } answers {
                persisted.set(pending)
                true
            }
            editor
        }
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns preferences

        val firstViewerStore = screenShareViewerPhoneControlCounterStore(context)
        val recreatedViewerStore = screenShareViewerPhoneControlCounterStore(context)

        assertEquals(89L, firstViewerStore.nextCounter("android-phone"))
        assertEquals(90L, recreatedViewerStore.nextCounter("android-phone"))
        assertEquals(90L, persisted.get())
    }
}
