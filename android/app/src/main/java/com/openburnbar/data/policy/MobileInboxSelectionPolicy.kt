package com.openburnbar.data.policy

data class MobileInboxSelectionState(
    val selectedID: String? = null,
    val pendingFocusID: String? = null,
    val filter: String = "active",
    val searchQuery: String = "",
    val focusRequestToken: Int = 0,
)

/** Cold/warm inbox focus. Source: iOS `AIInboxStore.focus` / `reconcileSelection`. */
object MobileInboxSelectionPolicy {
    fun focus(state: MobileInboxSelectionState, itemID: String?, recordIDs: List<String>): MobileInboxSelectionState {
        val pending = if (itemID != null && itemID !in recordIDs) itemID else null
        return state.copy(
            filter = "active",
            searchQuery = "",
            focusRequestToken = state.focusRequestToken + 1,
            selectedID = itemID ?: state.selectedID,
            pendingFocusID = if (itemID != null) pending else state.pendingFocusID,
        )
    }

    fun reconcile(state: MobileInboxSelectionState, visibleIDs: List<String>, recordIDs: List<String>): MobileInboxSelectionState {
        val selectedID = state.selectedID ?: return state
        if (state.pendingFocusID != null && state.pendingFocusID !in recordIDs) {
            return state
        }
        val released = if (state.pendingFocusID != null && state.pendingFocusID in recordIDs) {
            state.copy(pendingFocusID = null)
        } else {
            state
        }
        return if (selectedID !in visibleIDs) {
            released.copy(selectedID = visibleIDs.firstOrNull())
        } else {
            released
        }
    }
}
