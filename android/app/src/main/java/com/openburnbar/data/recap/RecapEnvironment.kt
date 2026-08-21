package com.openburnbar.data.recap

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface RecapPhase {
    data object Idle : RecapPhase
    data object Building : RecapPhase
    data class Ready(val recap: MonthlyRecap) : RecapPhase
    data class NotEnoughData(val window: RecapWindow) : RecapPhase
    data class Failed(val message: String) : RecapPhase
}

class RecapEnvironment(
    context: Context,
    private val source: RecapSource = FirestoreRecapSource(),
    private val accountID: String? = FirebaseAuth.getInstance().currentUser?.uid,
) : ViewModel() {

    private val store = RecapStore(context.applicationContext, accountID)

    private val _phase = MutableStateFlow<RecapPhase>(RecapPhase.Idle)
    val phase: StateFlow<RecapPhase> = _phase.asStateFlow()

    private val _selectedMonth = MutableStateFlow(RecapWindow.mostRecentCompleted())
    val selectedMonth: StateFlow<RecapWindow> = _selectedMonth.asStateFlow()

    private val _availableMonths = MutableStateFlow<List<RecapWindow>>(emptyList())
    val availableMonths: StateFlow<List<RecapWindow>> = _availableMonths.asStateFlow()

    private val _recap = MutableStateFlow<MonthlyRecap?>(null)
    val recap: StateFlow<MonthlyRecap?> = _recap.asStateFlow()

    private var loadJob: Job? = null

    init {
        refreshAvailableMonths()
        load(_selectedMonth.value)
    }

    fun selectMonth(window: RecapWindow) {
        if (window == _selectedMonth.value && _recap.value != null) return
        _selectedMonth.value = window
        _recap.value = null
        load(window)
    }

    fun refreshAvailableMonths() {
        viewModelScope.launch {
            val stored = store.availableMonths()
            val completed = RecapWindow.mostRecentCompleted()
            val current = RecapWindow.current()
            val combined = (stored + listOf(completed, current)).distinct().sortedDescending()
            _availableMonths.value = combined
        }
    }

    fun load(window: RecapWindow = _selectedMonth.value, forceRegenerate: Boolean = false) {
        loadJob?.cancel()
        _phase.value = RecapPhase.Building

        loadJob = viewModelScope.launch {
            try {
                if (!forceRegenerate) {
                    val cached = store.loadRecap(window)
                    if (cached != null) {
                        _recap.value = cached
                        _phase.value = RecapPhase.Ready(cached)
                        return@launch
                    }
                }
                executeRecapBuild(window)
            } catch (e: CancellationException) {
                throw e
            } catch (e: IllegalStateException) {
                _phase.value = RecapPhase.Failed(e.message ?: "Failed to generate monthly recap")
            } catch (e: IOException) {
                _phase.value = RecapPhase.Failed(e.message ?: "Network error loading monthly recap")
            } catch (e: com.google.firebase.FirebaseException) {
                _phase.value = RecapPhase.Failed(e.message ?: "Firestore error loading monthly recap")
            }
        }
    }

    private suspend fun executeRecapBuild(window: RecapWindow) {
        val (usages, isPartial) = source.loadUsages(window)
        val facts = RecapFactsBuilder.build(
            window = window,
            usages = usages,
            isPartial = isPartial,
        )
        store.saveFacts(facts)

        if (!facts.meetsMinimumSubstance && usages.isEmpty()) {
            _phase.value = RecapPhase.NotEnoughData(window)
            return
        }

        val prevFacts = loadOrFetchPreviousFacts(window)
        val history = store.loadAllFacts()
        val ctx = RecapContext(facts = facts, previousMonth = prevFacts, history = history)

        val candidates = RecapRuleEngine.generateCandidates(ctx)
        val cards = RecapRanker.rank(candidates)

        val title = RecapDeterministicVoice.title(ctx, cards)
        val closing = RecapDeterministicVoice.closing(ctx, cards)
        val sealState = if (window.hasEnded()) RecapSealState.SEALED else RecapSealState.PREVIEW

        val monthlyRecap = MonthlyRecap(
            window = window,
            title = title,
            cards = cards,
            closingSentence = closing,
            isPartial = isPartial,
            sealState = sealState,
        )

        store.saveRecap(monthlyRecap)
        _recap.value = monthlyRecap
        _phase.value = RecapPhase.Ready(monthlyRecap)
        refreshAvailableMonths()
    }

    private suspend fun loadOrFetchPreviousFacts(window: RecapWindow): RecapFacts? {
        val prevWindow = window.previous
        val existing = store.loadFacts(prevWindow)
        if (existing != null) return existing

        val (prevUsages, prevPartial) = source.loadUsages(prevWindow)
        if (prevUsages.isNotEmpty()) {
            val built = RecapFactsBuilder.build(
                window = prevWindow,
                usages = prevUsages,
                isPartial = prevPartial,
            )
            store.saveFacts(built)
            return built
        }
        return null
    }
}
