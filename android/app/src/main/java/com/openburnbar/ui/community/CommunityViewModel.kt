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
    val geoLabel: String,
    val geoConfidenceCopy: String,
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
    val isExportingLookingGlass: Boolean = false,
    val lookingGlassExportUrl: String? = null,
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

    fun joinCommunity(handle: String? = null, successMessage: String? = null) {
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
                val message = successMessage ?: "Community preferences saved."
                _uiState.update { it.copy(isJoining = false, actionMessage = message) }
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
                    resolvedCityKey = null,
                )
            consentStore.applyDraftChange(next)
            joinCommunity(
                successMessage =
                    "Approximate location was denied. World, country, and region preferences were saved; city ranking is off.",
            )
        }
    }

    fun exportLookingGlassBundle() {
        viewModelScope.launch {
            _uiState.update {
                it.copy(
                    isExportingLookingGlass = true,
                    error = null,
                    actionMessage = null,
                    lookingGlassExportUrl = null,
                )
            }
            try {
                val response = functions.exportLookingGlassBundle()
                val url = parseLookingGlassDownloadUrl(response)
                if (url == null) {
                    _uiState.update {
                        it.copy(
                            isExportingLookingGlass = false,
                            error = "Looking Glass export link was missing or invalid.",
                        )
                    }
                    return@launch
                }
                val traceCount = (response["traceCount"] as? Number)?.toLong()
                val message =
                    if (traceCount != null && traceCount > 0) {
                        "Looking Glass export ready ($traceCount traces). Link expires in about 15 minutes."
                    } else {
                        "Looking Glass export link ready. It expires in about 15 minutes."
                    }
                _uiState.update {
                    it.copy(
                        isExportingLookingGlass = false,
                        lookingGlassExportUrl = url,
                        actionMessage = message,
                    )
                }
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(
                        isExportingLookingGlass = false,
                        error = e.message ?: "Could not export Looking Glass bundle.",
                    )
                }
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

    fun clearLookingGlassExportUrl() {
        _uiState.update { it.copy(lookingGlassExportUrl = null) }
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
                        val geoLabel = communityGeoDisplayLabel(tier, geoKey)
                        CommunityLeaderboardCardState(
                            tier = tier,
                            geoKey = geoKey,
                            geoLabel = geoLabel,
                            geoConfidenceCopy = communityGeoConfidenceCopy(tier, geoKey),
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
