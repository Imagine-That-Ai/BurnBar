package com.openburnbar.data.media

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/**
 * 1:1 Kotlin port of `MediaPartnerSavePreferenceStore.swift`. Decision 3
 * of the Mercury Media master plan: per-paired-Mac save preferences for
 * inbound image attachments. First image from a given peer presents an
 * action sheet (Photos / Files); subsequent images use the saved choice.
 *
 * iOS persists in UserDefaults; Android uses DataStore Preferences keyed
 * by the peer iroh NodeId so the same per-partner persistence semantics
 * carry over and survive app updates.
 *
 * Settings → Media → "Per-partner save preferences" surfaces the list +
 * per-row "Forget" + global "Forget all".
 */
class MediaPartnerSavePreferenceStore(context: Context) {

    enum class SavePreference(val raw: String) {
        ASK_EACH_TIME("askEachTime"),
        PHOTOS("photos"),
        FILES("files");

        companion object {
            fun fromRaw(raw: String?): SavePreference? = values().firstOrNull { it.raw == raw }
        }
    }

    private val store = context.applicationContext.dataStore

    suspend fun preference(peerDeviceId: String): SavePreference {
        val raw = store.data.map { it[keyFor(peerDeviceId)] }.first()
        return SavePreference.fromRaw(raw) ?: SavePreference.ASK_EACH_TIME
    }

    fun preferenceFlow(peerDeviceId: String): Flow<SavePreference> =
        store.data.map { SavePreference.fromRaw(it[keyFor(peerDeviceId)]) ?: SavePreference.ASK_EACH_TIME }

    suspend fun setPreference(preference: SavePreference, peerDeviceId: String) {
        store.edit { prefs ->
            if (preference == SavePreference.ASK_EACH_TIME) {
                prefs.remove(keyFor(peerDeviceId))
            } else {
                prefs[keyFor(peerDeviceId)] = preference.raw
            }
        }
    }

    suspend fun forget(peerDeviceId: String) {
        store.edit { prefs -> prefs.remove(keyFor(peerDeviceId)) }
    }

    suspend fun forgetAll() {
        store.edit { prefs ->
            val keys = prefs.asMap().keys.filterIsInstance<Preferences.Key<String>>()
                .filter { it.name.startsWith(KEY_PREFIX) }
            keys.forEach { prefs.remove(it) }
        }
    }

    suspend fun storedPartners(): List<Pair<String, SavePreference>> {
        val snapshot = store.data.first()
        return snapshot.asMap().entries
            .mapNotNull { (key, value) ->
                if (!key.name.startsWith(KEY_PREFIX)) return@mapNotNull null
                val peerId = key.name.removePrefix(KEY_PREFIX)
                val pref = SavePreference.fromRaw(value as? String) ?: return@mapNotNull null
                peerId to pref
            }
            .sortedBy { it.first }
    }

    fun storedPartnersFlow(): Flow<List<Pair<String, SavePreference>>> = store.data.map { snapshot ->
        snapshot.asMap().entries
            .mapNotNull { (key, value) ->
                if (!key.name.startsWith(KEY_PREFIX)) return@mapNotNull null
                val peerId = key.name.removePrefix(KEY_PREFIX)
                val pref = SavePreference.fromRaw(value as? String) ?: return@mapNotNull null
                peerId to pref
            }
            .sortedBy { it.first }
    }

    private fun keyFor(peerDeviceId: String) = stringPreferencesKey(KEY_PREFIX + peerDeviceId)

    companion object {
        private const val KEY_PREFIX = "media.savePreference."
        private val Context.dataStore by preferencesDataStore(name = "mercury_media_partner_prefs")
    }
}
