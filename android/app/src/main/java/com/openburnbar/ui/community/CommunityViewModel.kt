package com.openburnbar.ui.community

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.community.CommunityConsentDraft
import com.openburnbar.data.community.CommunityConsentStore
import com.openburnbar.data.community.CommunityFunctions
import com.openburnbar.data.community.CommunityGeoTier
import com.openburnbar.data.community.CommunityRepository
import com.openburnbar.data.community.CommunityTimeWindow
import com.openburnbar.data.community.ConsentTriState
import com.openburnbar.data.community.usageForWindow
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.generated.FirestoreCommunityLeaderboardDoc
import com.openburnbar.data.models.generated.FirestoreCommunityProfileDoc
import com.openburnbar.data.models.generated.FirestoreCommunityShareSnapshotDoc
import com.openburnbar.data.models.generated.FirestorePercentileBands
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class CommunityLeaderboardCardState(
    val tier: CommunityGeoTier,
    val geoKey: String,
    val board: FirestoreCommunityLeaderboardDoc?,
    val isLoading: Boolean = false,
)

data class CommunityUiState(
    val isLoading: Boolean = true,
    val error: String? = null,
    val actionMessage: String? = null,
    val isJoining: Boolean = false,
    val isRevoking: Boolean = false,
    val profile: FirestoreCommunityProfileDoc? = null,
    val shareSnapshot: FirestoreCommunityShareSnapshotDoc? = null,
    val selectedWindow: CommunityTimeWindow = CommunityTimeWindow.SEVEN_DAY,
    val consentDraft: CommunityConsentDraft = CommunityConsentDraft(),
    val leaderboardCards: List<CommunityLeaderboardCardState> = emptyList(),
    val heroTokens: Long = 0,
    val heroCostUsd: Double = 0.0,
    val modelMix: Map<String, Double> = emptyMap(),
    val purposeMix: Map<String, Double> = emptyMap(),
    val percentiles: FirestorePercentileBands = FirestorePercentileBands(),
    val cohortSize: Long = 0,
    val hasJoined: Boolean = false,
)

class CommunityViewModel(
    application: Application,
    private val repository: CommunityRepository = CommunityRepository(),
    private val functions: CommunityFunctions = CommunityFunctions(),
    private val consentStore: CommunityConsentStore = CommunityConsentStore(application),
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(CommunityUiState())
    val uiState: StateFlow<CommunityUiState> = _uiState.asStateFlow()

    val consentDraft: StateFlow<CommunityConsentDraft> =
        consentStore.draft.stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5_000),
            CommunityConsentDraft(),
        )

    private var leaderboardJob: Job? = null

    init {
        viewModelScope.launch {
            consentStore.draft.collect { draft ->
                _uiState.update { it.copy(consentDraft = draft) }
            }
        }
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, error = null) }
            try {
                val consent = repository.fetchConsent()
                val profile = repository.fetchProfile()
                val snapshot = repository.fetchShareSnapshot()
                if (consent != null) {
                    consentStore.mergeFromServer(consent)
                }
                val window = _uiState.value.selectedWindow
                val usage = snapshot?.usageForWindow(window)
                _uiState.update {
                    it.copy(
                        isLoading = false,
                        profile = profile,
                        shareSnapshot = snapshot,
                        hasJoined = consent != null && consent.l2Rankings == "granted",
                        heroTokens = usage?.totalTokens ?: 0,
                        heroCostUsd = usage?.costUSD ?: 0.0,
                        modelMix = snapshot?.modelMix ?: emptyMap(),
                        purposeMix = snapshot?.purposeMix ?: emptyMap(),
                    )
                }
                restartLeaderboardListening()
            } catch (e: FirestoreRepository.NotSignedInException) {
                _uiState.update { it.copy(isLoading = false, error = "Sign in to view Community.") }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false, error = e.message ?: "Could not load community.") }
            }
        }
    }

    fun setTimeWindow(window: CommunityTimeWindow) {
        _uiState.update { state ->
            val usage = state.shareSnapshot?.usageForWindow(window)
            state.copy(
                selectedWindow = window,
                heroTokens = usage?.totalTokens ?: 0,
                heroCostUsd = usage?.costUSD ?: 0.0,
            )
        }
        restartLeaderboardListening()
    }

    fun updateConsentDraft(mutator: (CommunityConsentDraft) -> CommunityConsentDraft) {
        viewModelScope.launch {
            val next = mutator(_uiState.value.consentDraft)
            consentStore.applyDraftChange(next)
        }
    }

    fun joinCommunity(handle: String? = null) {
        viewModelScope.launch {
            _uiState.update { it.copy(isJoining = true, actionMessage = null, error = null) }
            try {
                var draft = consentStore.draft.first()
                draft = consentStore.syncResolvedCityKeyFromOsIfNeeded(draft)
                val profile = _uiState.value.profile
                val payload =
                    draft.toJoinPayload(
                        handle = handle ?: profile?.handle,
                        countryCode = profile?.countryCode,
                        regionKey = profile?.regionKey,
                    )
                functions.joinCommunity(payload)
                _uiState.update { it.copy(isJoining = false, actionMessage = "Community preferences saved.") }
                refresh()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(isJoining = false, error = e.message ?: "Could not join community.")
                }
            }
        }
    }

    fun declineCityLocationPermission() {
        viewModelScope.launch {
            val next =
                _uiState.value.consentDraft.copy(
                    l2City = ConsentTriState.DECLINED,
                    locationConsent = ConsentTriState.DECLINED,
                )
            consentStore.applyDraftChange(next)
            _uiState.update {
                it.copy(
                    error = "City leaderboard needs approximate location permission. City sharing is off.",
                    isJoining = false,
                )
            }
        }
    }

    fun revokeParticipation() {
        viewModelScope.launch {
            _uiState.update { it.copy(isRevoking = true, error = null) }
            try {
                functions.revokeCommunityParticipation()
                _uiState.update { it.copy(isRevoking = false, actionMessage = "Community participation paused.") }
                refresh()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(isRevoking = false, error = e.message ?: "Could not revoke participation.")
                }
            }
        }
    }

    fun clearActionMessage() {
        _uiState.update { it.copy(actionMessage = null) }
    }

    private fun restartLeaderboardListening() {
        leaderboardJob?.cancel()
        leaderboardJob =
            viewModelScope.launch {
                val window = _uiState.value.selectedWindow.wire
                val profile = _uiState.value.profile
                val snapshot = _uiState.value.shareSnapshot
                val tierSpecs =
                    listOf(
                        CommunityGeoTier.CITY to (snapshot?.cityKey ?: profile?.cityKey),
                        CommunityGeoTier.REGION to (snapshot?.regionKey ?: profile?.regionKey),
                        CommunityGeoTier.COUNTRY to (snapshot?.countryCode ?: profile?.countryCode),
                        CommunityGeoTier.WORLD to "world",
                    )
                val cards =
                    tierSpecs.map { (tier, key) ->
                        val geoKey =
                            when {
                                tier == CommunityGeoTier.WORLD -> "world"
                                !key.isNullOrBlank() -> key
                                else -> tier.wire
                            }
                        CommunityLeaderboardCardState(
                            tier = tier,
                            geoKey = geoKey,
                            board = null,
                            isLoading = tier == CommunityGeoTier.WORLD || !key.isNullOrBlank(),
                        )
                    }
                _uiState.update { it.copy(leaderboardCards = cards) }

                for (card in cards) {
                    if (card.tier != CommunityGeoTier.WORLD && card.geoKey == card.tier.wire) continue
                    val tier = card.tier
                    val geoKey = card.geoKey
                    launch {
                        repository.listenLeaderboard(window, tier.wire, geoKey)
                            .catch { }
                            .collect { board ->
                                _uiState.update { state ->
                                    val updated =
                                        state.leaderboardCards.map { existing ->
                                            if (existing.tier == tier && existing.geoKey == geoKey) {
                                                existing.copy(board = board, isLoading = false)
                                            } else {
                                                existing
                                            }
                                        }
                                    val primaryBoard =
                                        updated.mapNotNull { it.board }
                                            .firstOrNull { !it.belowThreshold }
                                    state.copy(
                                        leaderboardCards = updated,
                                        percentiles = primaryBoard?.percentiles ?: FirestorePercentileBands(),
                                        cohortSize = primaryBoard?.cohortSize ?: 0,
                                    )
                                }
                            }
                    }
                }
            }
    }

    override fun onCleared() {
        leaderboardJob?.cancel()
        super.onCleared()
    }
}
