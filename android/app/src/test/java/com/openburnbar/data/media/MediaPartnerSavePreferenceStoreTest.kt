package com.openburnbar.data.media

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-JVM coverage for the per-partner save-preference DataStore. We
 * stub `Context.applicationContext` + `Context.filesDir` so the
 * `preferencesDataStore(name=...)` delegate hits a tempfolder-backed
 * preferences file without an Android emulator.
 */
class MediaPartnerSavePreferenceStoreTest {

    private lateinit var tempDir: File
    private lateinit var context: Context

    @Before
    fun setUp() {
        tempDir = createTempDir(prefix = "mercury-partner-prefs")
        context = mockk(relaxed = true)
        every { context.applicationContext } returns context
        every { context.filesDir } returns tempDir
        // The DataStore delegate is cached by name, so reset state at
        // start so test ordering doesn't bleed.
        runTest { MediaPartnerSavePreferenceStore(context).forgetAll() }
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    @Test
    fun missing_partner_defaults_to_ask_each_time() = runTest {
        val store = MediaPartnerSavePreferenceStore(context)
        assertEquals(
            MediaPartnerSavePreferenceStore.SavePreference.ASK_EACH_TIME,
            store.preference("peer-A"),
        )
    }

    @Test
    fun set_preference_round_trips_to_disk() = runTest {
        val store = MediaPartnerSavePreferenceStore(context)
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.PHOTOS, "peer-B")
        assertEquals(
            MediaPartnerSavePreferenceStore.SavePreference.PHOTOS,
            store.preference("peer-B"),
        )
    }

    @Test
    fun setting_to_ask_each_time_clears_the_entry() = runTest {
        val store = MediaPartnerSavePreferenceStore(context)
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.FILES, "peer-C")
        assertEquals(
            MediaPartnerSavePreferenceStore.SavePreference.FILES,
            store.preference("peer-C"),
        )
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.ASK_EACH_TIME, "peer-C")
        assertEquals(
            MediaPartnerSavePreferenceStore.SavePreference.ASK_EACH_TIME,
            store.preference("peer-C"),
        )
        assertEquals(emptyList<Pair<String, MediaPartnerSavePreferenceStore.SavePreference>>(), store.storedPartners())
    }

    @Test
    fun forget_removes_only_the_targeted_partner() = runTest {
        val store = MediaPartnerSavePreferenceStore(context)
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.PHOTOS, "peer-A")
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.FILES, "peer-B")
        store.forget("peer-A")
        assertEquals(
            listOf("peer-B" to MediaPartnerSavePreferenceStore.SavePreference.FILES),
            store.storedPartners(),
        )
    }

    @Test
    fun forget_all_clears_every_partner() = runTest {
        val store = MediaPartnerSavePreferenceStore(context)
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.PHOTOS, "peer-1")
        store.setPreference(MediaPartnerSavePreferenceStore.SavePreference.FILES, "peer-2")
        store.forgetAll()
        assertEquals(emptyList<Pair<String, MediaPartnerSavePreferenceStore.SavePreference>>(), store.storedPartners())
    }
}
