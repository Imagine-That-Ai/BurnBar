package com.openburnbar.data.community

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.openburnbar.data.models.generated.FirestoreCommunityConsentDoc
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** Tri-state consent ladder values — mirrors server + shared IA. */
enum class ConsentTriState {
    UNSET,
    GRANTED,
    DECLINED,
    ;

    fun wireValue(): String = when (this) {
        UNSET -> "unset"
        GRANTED -> "granted"
        DECLINED -> "declined"
    }

    fun callableWireValue(): String = when (this) {
        GRANTED -> "granted"
        UNSET, DECLINED -> "declined"
    }

    companion object {
        fun fromWire(value: String?): ConsentTriState = when (value?.lowercase()) {
            "granted" -> GRANTED
            "declined" -> DECLINED
            else -> UNSET
        }
    }
}

/** Local draft of community consent before syncing via `joinCommunity`. */
data class CommunityConsentDraft(
    val l1Analytics: ConsentTriState = ConsentTriState.UNSET,
    val l2Rankings: ConsentTriState = ConsentTriState.UNSET,
    val l2World: ConsentTriState = ConsentTriState.UNSET,
    val l2Country: ConsentTriState = ConsentTriState.UNSET,
    val l2Region: ConsentTriState = ConsentTriState.UNSET,
    val l2City: ConsentTriState = ConsentTriState.UNSET,
    val l3LookingGlass: ConsentTriState = ConsentTriState.UNSET,
    val locationConsent: ConsentTriState = ConsentTriState.UNSET,
    val resolvedCityKey: String? = null,
) {
    fun toJoinPayload(handle: String? = null, countryCode: String? = null, regionKey: String? = null, cityKey: String? = resolvedCityKey): Map<String, Any?> {
        val payload = mutableMapOf<String, Any?>(
            "l1Analytics" to l1Analytics.callableWireValue(),
            "l2Rankings" to l2Rankings.callableWireValue(),
            "l2World" to l2World.callableWireValue(),
            "l2Country" to l2Country.callableWireValue(),
            "l2Region" to l2Region.callableWireValue(),
            "l2City" to l2City.callableWireValue(),
            "l3LookingGlass" to l3LookingGlass.callableWireValue(),
            "locationConsent" to locationConsent.callableWireValue(),
            "timezone" to TimeZone.getDefault().id,
            "locale" to Locale.getDefault().toLanguageTag(),
        )
        if (!handle.isNullOrBlank()) payload["handle"] = handle.trim()
        if (l2Country == ConsentTriState.GRANTED && !countryCode.isNullOrBlank()) payload["countryCode"] = countryCode
        if (l2Region == ConsentTriState.GRANTED && !regionKey.isNullOrBlank()) payload["regionKey"] = regionKey
        if (
            l2City == ConsentTriState.GRANTED &&
            locationConsent == ConsentTriState.GRANTED &&
            !cityKey.isNullOrBlank()
        ) {
            payload["cityKey"] = cityKey
        }
        return payload
    }
}

fun FirestoreCommunityConsentDoc.toDraft(): CommunityConsentDraft = CommunityConsentDraft(
    l1Analytics = ConsentTriState.fromWire(l1Analytics),
    l2Rankings = ConsentTriState.fromWire(l2Rankings),
    l2World = ConsentTriState.fromWire(l2Tiers.world),
    l2Country = ConsentTriState.fromWire(l2Tiers.country),
    l2Region = ConsentTriState.fromWire(l2Tiers.region),
    l2City = ConsentTriState.fromWire(l2Tiers.city),
    l3LookingGlass = ConsentTriState.fromWire(l3LookingGlass),
    locationConsent = ConsentTriState.fromWire(locationConsent),
)

private val Context.communityConsentDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "burnbar_community_consent",
)

/**
 * DataStore-backed tri-state consent draft. Server docs remain authoritative after join;
 * this store holds local ladder state for the consent center UI.
 */
class CommunityConsentStore(private val context: Context) {
    private val dataStore = context.communityConsentDataStore

    val draft: Flow<CommunityConsentDraft> =
        dataStore.data.map { prefs ->
            CommunityConsentDraft(
                l1Analytics = ConsentTriState.fromWire(prefs[KEY_L1]),
                l2Rankings = ConsentTriState.fromWire(prefs[KEY_L2]),
                l2World = ConsentTriState.fromWire(prefs[KEY_L2_WORLD]),
                l2Country = ConsentTriState.fromWire(prefs[KEY_L2_COUNTRY]),
                l2Region = ConsentTriState.fromWire(prefs[KEY_L2_REGION]),
                l2City = ConsentTriState.fromWire(prefs[KEY_L2_CITY]),
                l3LookingGlass = ConsentTriState.fromWire(prefs[KEY_L3]),
                locationConsent = ConsentTriState.fromWire(prefs[KEY_LOCATION]),
                resolvedCityKey = prefs[KEY_RESOLVED_CITY],
            )
        }

    suspend fun replace(draft: CommunityConsentDraft) {
        dataStore.edit { prefs ->
            prefs[KEY_L1] = draft.l1Analytics.wireValue()
            prefs[KEY_L2] = draft.l2Rankings.wireValue()
            prefs[KEY_L2_WORLD] = draft.l2World.wireValue()
            prefs[KEY_L2_COUNTRY] = draft.l2Country.wireValue()
            prefs[KEY_L2_REGION] = draft.l2Region.wireValue()
            prefs[KEY_L2_CITY] = draft.l2City.wireValue()
            prefs[KEY_L3] = draft.l3LookingGlass.wireValue()
            prefs[KEY_LOCATION] = draft.locationConsent.wireValue()
            draft.resolvedCityKey?.let { prefs[KEY_RESOLVED_CITY] = it }
                ?: run { prefs.remove(KEY_RESOLVED_CITY) }
        }
    }

    /** When city tier + coarse location consent are on, resolve OS city and persist on the draft. */
    suspend fun syncResolvedCityKeyFromOsIfNeeded(draft: CommunityConsentDraft): CommunityConsentDraft {
        if (
            draft.l2City != ConsentTriState.GRANTED ||
            draft.locationConsent != ConsentTriState.GRANTED
        ) {
            return draft
        }
        val key = CommunityLocationResolver.resolveCoarseCityKey(context) ?: return draft
        val updated = draft.copy(resolvedCityKey = key)
        replace(updated)
        return updated
    }

    suspend fun applyDraftChange(next: CommunityConsentDraft): CommunityConsentDraft {
        replace(next)
        return syncResolvedCityKeyFromOsIfNeeded(next)
    }

    suspend fun mergeFromServer(doc: FirestoreCommunityConsentDoc) {
        val keepCity = draft.first().resolvedCityKey
        replace(doc.toDraft().copy(resolvedCityKey = keepCity))
    }

    companion object {
        private val KEY_L1 = stringPreferencesKey("l1_analytics")
        private val KEY_L2 = stringPreferencesKey("l2_rankings")
        private val KEY_L2_WORLD = stringPreferencesKey("l2_world")
        private val KEY_L2_COUNTRY = stringPreferencesKey("l2_country")
        private val KEY_L2_REGION = stringPreferencesKey("l2_region")
        private val KEY_L2_CITY = stringPreferencesKey("l2_city")
        private val KEY_L3 = stringPreferencesKey("l3_looking_glass")
        private val KEY_LOCATION = stringPreferencesKey("location_consent")
        private val KEY_RESOLVED_CITY = stringPreferencesKey("resolved_city_key")
    }
}
