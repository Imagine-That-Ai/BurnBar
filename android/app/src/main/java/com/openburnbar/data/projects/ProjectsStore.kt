package com.openburnbar.data.projects

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProjectSummary
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

// MARK: - Projects Store (Android parity, Hermes Square §6.3)
//
// Port of the iOS `ProjectsStore` that the brand zone and Project Memory
// Wiki sections read. Loads `users/{uid}/projects` once on demand and
// exposes `summaries` + `topByCost(limit)` + `mostRecent(limit)`.
//
// Lives separately from `data/stores/ProjectsStore.kt` (which is a
// ViewModel-shaped flavor of the same data) so the parity surface stays
// callable from non-Compose contexts (mission console host, brand zone
// snapshot).

class ProjectsStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val _summaries = MutableStateFlow<List<ProjectSummary>>(emptyList())
    val summaries: StateFlow<List<ProjectSummary>> = _summaries.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun load() {
        scope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                _summaries.value = repo.fetchProjects()
            } catch (e: Exception) {
                _error.value = e.localizedMessage
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun topByCost(limit: Int = 3): List<ProjectSummary> =
        _summaries.value.sortedByDescending { it.totalCost }.take(limit)

    fun mostRecent(limit: Int = 8): List<ProjectSummary> =
        _summaries.value.take(limit)

    companion object {
        @Volatile private var instance: ProjectsStore? = null

        fun shared(): ProjectsStore =
            instance ?: synchronized(this) {
                instance ?: ProjectsStore().also { instance = it }
            }
    }
}
