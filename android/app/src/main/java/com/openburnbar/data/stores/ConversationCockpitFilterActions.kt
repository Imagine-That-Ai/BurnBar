package com.openburnbar.data.stores

/** Filter and saved-query mutations for [ConversationCockpitStore]. */
internal class ConversationCockpitFilterActions(
    private val store: ConversationCockpitStore,
) {
    private val bindings get() = store.bindings

    fun toggleProvider(provider: String) {
        bindings.mutateSelectedProviders { providers ->
            providers.toMutableSet().apply {
                if (!add(provider)) remove(provider)
            }
        }
    }

    fun setModel(model: String?) {
        bindings.setSelectedModel(model)
        bindings.bumpSignature()
    }

    fun setProjectQuery(query: String) {
        bindings.setProjectQueryValue(query)
        bindings.bumpSignature()
    }

    fun setDateRange(fromMs: Long?, toMs: Long?) {
        bindings.setDateRangeValues(fromMs, toMs)
        bindings.bumpSignature()
    }

    fun setSort(field: ConversationSortField, direction: ConversationSortDirection) {
        bindings.setSortValues(field, direction)
        bindings.bumpSignature()
    }

    fun clearFilters() {
        bindings.clearFilterValues()
        bindings.bumpSignature()
    }

    fun saveCurrentQuery(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        val query =
            SavedConversationQuery(
                id = java.util.UUID.randomUUID().toString(),
                name = trimmed,
                providers = store.selectedProviders.value.sorted(),
                model = store.selectedModel.value,
                projectQuery = "",
                sortField = store.sortField.value.field,
                sortDirection = store.sortDirection.value.token,
                dateFromMs = store.dateFromMs.value,
                dateToMs = store.dateToMs.value,
            )
        bindings.replaceSavedQueries(
            listOf(query) + store.savedQueries.value.filterNot { it.name.equals(trimmed, ignoreCase = true) },
        )
        bindings.persistSavedQueries()
    }

    fun applySavedQuery(query: SavedConversationQuery) {
        bindings.applySavedQueryValues(query)
        bindings.bumpSignature()
    }

    fun deleteSavedQuery(query: SavedConversationQuery) {
        bindings.replaceSavedQueries(store.savedQueries.value.filterNot { it.id == query.id })
        bindings.persistSavedQueries()
    }
}

/** Query execution for [ConversationCockpitStore]. */
internal class ConversationCockpitQueryActions(
    private val store: ConversationCockpitStore,
) {
    fun runQuery(reset: Boolean) = store.runQueryInternal(reset)

    fun loadNextPage() = store.runQueryInternal(reset = false)

    suspend fun loadTranscript(row: CockpitConversationRow): String = store.loadTranscriptInternal(row)
}
