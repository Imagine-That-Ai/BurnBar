package com.openburnbar.data.stores

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

internal object ConversationCockpitSavedQueryPersistence {
    fun load(prefs: SharedPreferences, key: String): List<SavedConversationQuery> {
        val json = prefs.getString(key, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull { index ->
                val obj = array.optJSONObject(index) ?: return@mapNotNull null
                SavedConversationQuery(
                    id = obj.optString("id"),
                    name = obj.optString("name"),
                    providers =
                    obj.optJSONArray("providers")?.let { arr ->
                        (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotBlank() } }
                    } ?: emptyList(),
                    model = obj.optString("model").takeIf { it.isNotBlank() },
                    projectQuery = obj.optString("projectQuery"),
                    sortField = obj.optString("sortField", "updatedAt"),
                    sortDirection = obj.optString("sortDirection", "desc"),
                    dateFromMs = if (obj.has("dateFromMs") && !obj.isNull("dateFromMs")) obj.optLong("dateFromMs") else null,
                    dateToMs = if (obj.has("dateToMs") && !obj.isNull("dateToMs")) obj.optLong("dateToMs") else null,
                )
            }
        }.getOrDefault(emptyList())
    }

    fun persist(prefs: SharedPreferences, key: String, queries: List<SavedConversationQuery>) {
        val array = JSONArray()
        for (query in queries) {
            val obj = JSONObject()
            obj.put("id", query.id)
            obj.put("name", query.name)
            obj.put("providers", JSONArray(query.providers))
            obj.put("model", query.model ?: JSONObject.NULL)
            obj.put("projectQuery", query.projectQuery)
            obj.put("sortField", query.sortField)
            obj.put("sortDirection", query.sortDirection)
            obj.put("dateFromMs", query.dateFromMs ?: JSONObject.NULL)
            obj.put("dateToMs", query.dateToMs ?: JSONObject.NULL)
            array.put(obj)
        }
        prefs.edit().putString(key, array.toString()).apply()
    }
}
