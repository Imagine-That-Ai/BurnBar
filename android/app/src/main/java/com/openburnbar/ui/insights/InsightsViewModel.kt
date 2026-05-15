package com.openburnbar.ui.insights

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.services.AndroidBurnBarHostedInsightGateway
import com.openburnbar.data.insights.services.AndroidHermesInsightAnalysisGateway
import com.openburnbar.data.insights.services.AndroidInsightCredentialStore
import com.openburnbar.data.insights.services.AndroidInsightAnalysisEngine
import com.openburnbar.data.insights.services.AndroidInsightGatewayRegistry
import com.openburnbar.data.insights.services.FirestoreInsightDataSource
import com.openburnbar.data.insights.services.InsightAggregator
import com.openburnbar.data.insights.services.InsightAnalysisEngine
import com.openburnbar.data.insights.services.InsightDataSource
import com.openburnbar.data.insights.services.RuleBasedInsightAnalysisEngine
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.repos.InsightAnalysisAuditLogRepository
import com.openburnbar.data.repos.InsightAnalysisCacheRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class InsightsViewModel(
    application: Application,
    private val dataSource: InsightDataSource = FirestoreInsightDataSource(),
    /**
     * Optional pre-built Hermes Insights gateway. The shell wires this
     * when the user's Hermes relay is reachable so follow-up taps
     * stream through Hermes; the default `null` keeps every existing
     * test + screen factory working unchanged. The secondary
     * constructor below preserves the no-arg shape `viewModel()` uses.
     */
    private val hermesGateway: AndroidHermesInsightAnalysisGateway? = null,
) : AndroidViewModel(application) {

    constructor(application: Application) : this(application, FirestoreInsightDataSource(), null)

    private val auditLog = InsightAnalysisAuditLogRepository(application)
    private val cache = InsightAnalysisCacheRepository(application)
    private val credentialStore = AndroidInsightCredentialStore(application)
    private val gateways = AndroidInsightGatewayRegistry.defaultGateways(
        credentialStore,
        hermesProvider = { hermesGateway }
    ).associateBy { it.providerKey }
    private val preferences = application.getSharedPreferences("insights_model_preferences", Application.MODE_PRIVATE)
    private val missionDispatcher = CLIAgentMissionDispatcher()

    private val _canvas = MutableStateFlow<InsightCanvas?>(null)
    val canvas = _canvas.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _selectedWidgetId = MutableStateFlow<String?>(null)
    val selectedWidgetId = _selectedWidgetId.asStateFlow()

    private val _analysis = MutableStateFlow<InsightAnalysisResult?>(null)
    val analysis = _analysis.asStateFlow()

    sealed interface MissionStatus {
        data object Idle : MissionStatus
        data class Dispatched(val title: String, val runtime: String) : MissionStatus
        data class Tracking(val mission: CLIAgentMissionSnapshot) : MissionStatus
        data class Failed(val title: String, val message: String) : MissionStatus
    }

    private val _missionStatus = MutableStateFlow<MissionStatus>(MissionStatus.Idle)
    val missionStatus = _missionStatus.asStateFlow()
    private var missionObservationJob: Job? = null

    private val localRulesModel = InsightModelTag(
        providerKey = "local-rules",
        modelID = "local-rules-v1",
        displayName = "Local rules",
        egressTier = InsightEgressTier.LOCAL_ONLY,
        stampedAt = java.time.Instant.now().toString()
    )

    private val _modelOptions = MutableStateFlow(listOf(localRulesModel) + gateways.values.flatMap { it.models })
    val modelOptions = _modelOptions.asStateFlow()

    private val _selectedModel = MutableStateFlow(loadSelectedModel())
    val selectedModel = _selectedModel.asStateFlow()

    private val _localOnlyMode = MutableStateFlow(preferences.getBoolean(KEY_LOCAL_ONLY, false))
    val localOnlyMode = _localOnlyMode.asStateFlow()

    private fun analysisEngine(): InsightAnalysisEngine = AndroidInsightAnalysisEngine(
        auditLog = auditLog,
        cache = cache,
        gateways = gateways,
        restrictToLocalOnly = _localOnlyMode.value
    )

    private fun loadSelectedModel(): InsightModelTag {
        val provider = preferences.getString(KEY_PROVIDER, null)
        val modelID = preferences.getString(KEY_MODEL_ID, null)
        if (!provider.isNullOrBlank() && !modelID.isNullOrBlank()) {
            _modelOptions.value.firstOrNull { it.providerKey == provider && it.modelID == modelID }?.let { return it }
        }
        return localRulesModel
    }

    private fun persistSelectedModel(modelTag: InsightModelTag) {
        preferences.edit()
            .putString(KEY_PROVIDER, modelTag.providerKey)
            .putString(KEY_MODEL_ID, modelTag.modelID)
            .putString(KEY_DISPLAY_NAME, modelTag.displayName)
            .putBoolean(KEY_LOCAL_ONLY, _localOnlyMode.value)
            .apply()
    }

    companion object {
        private const val KEY_PROVIDER = "provider"
        private const val KEY_MODEL_ID = "modelID"
        private const val KEY_DISPLAY_NAME = "displayName"
        private const val KEY_LOCAL_ONLY = "localOnly"
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                runAnalysis("Generate the default Android Insights intelligence brief.")
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                runAnalysis("Refresh the Android Insights intelligence brief.")
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun ask(prompt: String) {
        if (prompt.isBlank()) return
        viewModelScope.launch {
            _isLoading.value = true
            try {
                runAnalysis(prompt.trim(), InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP)
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun launchMission(
        title: String,
        prompt: String,
        missionKind: String = missionKind(prompt),
        requestedRuntime: String = "auto",
        targetProject: String? = null,
        depth: String = "standard",
        approvalMode: String = "existing_policy",
        commandsAllowed: Boolean = false,
        fileEditsAllowed: Boolean = false,
    ) {
        val trimmedPrompt = prompt.trim()
        val trimmedTitle = title.trim().ifEmpty { "Insights mission" }
        if (trimmedPrompt.isEmpty()) return
        viewModelScope.launch {
            try {
                val requestID = missionDispatcher.dispatch(
                    title = trimmedTitle,
                    prompt = trimmedPrompt,
                    missionKind = missionKind,
                    requestedRuntime = requestedRuntime,
                    targetProject = targetProject,
                    depth = depth,
                    approvalMode = approvalMode,
                    commandsAllowed = commandsAllowed,
                    fileEditsAllowed = fileEditsAllowed,
                )
                _missionStatus.value = MissionStatus.Dispatched(
                    trimmedTitle,
                    if (requestedRuntime == "auto") "Mac agent fleet" else requestedRuntime,
                )
                observeMission(requestID, trimmedTitle)
            } catch (e: Exception) {
                _missionStatus.value = MissionStatus.Failed(trimmedTitle, e.message ?: "Mission dispatch failed.")
            }
        }
    }

    fun dismissMissionStatus() {
        missionObservationJob?.cancel()
        missionObservationJob = null
        _missionStatus.value = MissionStatus.Idle
    }

    fun respondToMissionApproval(requestID: String, approve: Boolean) {
        viewModelScope.launch {
            try {
                missionDispatcher.respondToApproval(requestID, approve)
            } catch (e: Exception) {
                _missionStatus.value = MissionStatus.Failed(
                    "Mission approval",
                    e.message ?: "Mission approval response failed.",
                )
            }
        }
    }

    fun selectModel(modelTag: InsightModelTag) {
        _selectedModel.value = modelTag
        persistSelectedModel(modelTag)
    }

    fun setLocalOnlyMode(enabled: Boolean) {
        _localOnlyMode.value = enabled
        preferences.edit().putBoolean(KEY_LOCAL_ONLY, enabled).apply()
        if (enabled && _selectedModel.value.egressTier != InsightEgressTier.LOCAL_ONLY) {
            selectModel(localRulesModel)
        }
    }

    fun selectWidget(id: String?) {
        _selectedWidgetId.value = id
    }

    fun changeTheme(theme: InsightTheme) {
        val current = _canvas.value ?: return
        _canvas.value = current.copy(theme = theme)
    }

    fun removeWidget(widgetId: String) {
        val current = _canvas.value ?: return
        _canvas.value = current.remove(widgetId)
        if (_selectedWidgetId.value == widgetId) {
            _selectedWidgetId.value = null
        }
    }

    private suspend fun runAnalysis(
        prompt: String,
        instruction: InsightAnalysisRequest.Instruction = InsightAnalysisRequest.Instruction.DEFAULT_BRIEF
    ) {
        val filter = _canvas.value?.filter ?: InsightFilter()
        val digest = dataSource.buildDigest(filter)
        val context = InsightAggregator.buildContext(
            digest = digest,
            includedDataSources = listOf(
                "firestore_rollups",
                "quota_snapshots",
                "provider_summaries",
                "model_summaries",
                "prior_android_insight_runs",
                "audit_history"
            ),
            priorRunSummaries = emptyList()
        )
        val request = InsightAnalysisRequest(
            prompt = prompt,
            context = context,
            currentCanvas = _canvas.value,
            selectedModel = modelForAnalysis(instruction),
            instruction = instruction,
            allowDeepTranscriptAnalysis = false,
            maxGeneratedWidgets = 6
        )
        val result = analysisEngine().analyze(request)
        _analysis.value = result
        _canvas.value = RuleBasedInsightAnalysisEngine.materializeCanvas(result, prompt)
    }

    private fun modelForAnalysis(instruction: InsightAnalysisRequest.Instruction): InsightModelTag {
        val selected = _selectedModel.value
        if (instruction != InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) return selected
        if (selected.providerKey != "local-rules") return selected
        val available = if (_localOnlyMode.value) {
            _modelOptions.value.filter { it.egressTier == InsightEgressTier.LOCAL_ONLY }
        } else {
            _modelOptions.value
        }
        // Preference order: user-relay (Hermes) → user-key cloud → Ollama
        // → BurnBar hosted → anything non-local-rules.
        return available.firstOrNull { it.providerKey == "hermes" }
            ?: available.firstOrNull {
                it.egressTier != InsightEgressTier.LOCAL_ONLY
                    && it.providerKey != "ollama"
                    && it.providerKey != AndroidBurnBarHostedInsightGateway.PROVIDER_KEY
            }
            ?: available.firstOrNull { it.providerKey == "ollama" }
            ?: available.firstOrNull { it.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY }
            ?: available.firstOrNull { it.providerKey != "local-rules" }
            ?: selected
    }

    private fun missionKind(prompt: String): String {
        val lowered = prompt.lowercase()
        return when {
            "diligence" in lowered || "security" in lowered || "launch-readiness" in lowered -> "diligence"
            "debt" in lowered || "modernization" in lowered || "architecture" in lowered -> "debt"
            else -> "creative"
        }
    }

    private fun observeMission(requestID: String, fallbackTitle: String) {
        missionObservationJob?.cancel()
        missionObservationJob = viewModelScope.launch {
            missionDispatcher.observe(requestID)
                .catch { e ->
                    _missionStatus.value = MissionStatus.Failed(
                        fallbackTitle,
                        e.message ?: "Mission status listener failed."
                    )
                    missionObservationJob = null
                }
                .collect { snapshot ->
                    _missionStatus.value = MissionStatus.Tracking(snapshot)
                    if (snapshot.isTerminal) {
                        missionObservationJob?.cancel()
                        missionObservationJob = null
                    }
                }
        }
    }

    override fun onCleared() {
        missionObservationJob?.cancel()
        missionObservationJob = null
        super.onCleared()
    }
}
