package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.AssistantChatHistoryStore

/** Model/history preference mutations for [HermesService]. */
internal class HermesServicePreferenceActions(
    private val service: HermesService,
) {
    fun bindHistoryStore(store: AssistantChatHistoryStore) {
        service.historyStoreInternal = store
    }

    fun setChatTilePreferences(preferences: ChatTilePreferences) {
        service.chatTilePreferencesInternal = preferences.sanitized()
    }

    fun setToolAtomNavigator(navigator: HermesAtomNavigator?) {
        service.atomNavigatorInternal = navigator
    }

    fun selectModel(option: HermesRuntimeModelOption) {
        service.selectedModelIDInternal.value = option.modelID
    }

    fun toggleFavoriteModel(option: HermesRuntimeModelOption) {
        val current = service.favoriteModelIDsInternal.value.toMutableSet()
        if (current.contains(option.modelID)) {
            current.remove(option.modelID)
        } else {
            current.add(option.modelID)
        }
        service.favoriteModelIDsInternal.value = current
    }
}
