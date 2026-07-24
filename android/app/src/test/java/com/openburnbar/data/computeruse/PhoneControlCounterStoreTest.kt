package com.openburnbar.data.computeruse

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneControlCounterStoreTest {
    @Test
    fun sharedPreferencesStoresAllocateUniqueCountersAcrossInstances() = runBlocking {
        val persisted = AtomicLong(0)
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
        val stores =
            listOf(
                SharedPreferencesPhoneControlCounterStore(context),
                SharedPreferencesPhoneControlCounterStore(context),
            )

        val allocated =
            (0 until 100).map { index ->
                async(Dispatchers.Default) {
                    stores[index % stores.size].nextCounter("android-phone-shared")
                }
            }.awaitAll()

        assertEquals((1L..100L).toList(), allocated.sorted())
        assertEquals(100L, persisted.get())
    }
}
