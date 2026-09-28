package com.openburnbar.data.recap

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

sealed interface RecapPhase {
    data object Idle : RecapPhase
    data object Building : RecapPhase
    data class Ready(val recap: MonthlyRecap) : RecapPhase
    data class NotEnoughData(val window: RecapWindow) : RecapPhase
    data class Failed(val message: String) : RecapPhase
}

/**
 * Drives the monthly Recap screen for whichever Firebase account is signed in.
 *
 * The source and store are scoped to one account. When the auth identity
 * changes, the in-flight build is cancelled, the shown recap is cleared, and a
 * fresh source/store pair for the new uid takes over, so one account's cached
 * recap is never shown to another.
 */
class RecapEnvironment internal constructor(
    private val sourceFactory: (accountID: String?) -> RecapSource,
    private val storeFactory: (accountID: String?) -> RecapStore,
    initialAccountID: String?,
    accountIDs: Flow<String?>,
) : ViewModel() {

    constructor(context: Context, auth: FirebaseAuth = FirebaseAuth.getInstance()) : this(
        sourceFactory = { FirestoreRecapSource() },
        storeFactory = { RecapStore(context.applicationContext, it) },
        initialAccountID = auth.currentUser?.uid,
        accountIDs = auth.accountIDs(),
    )

    private inner class AccountScope(val accountID: String?) {
        val store: RecapStore = storeFactory(accountID)
        val source: RecapSource by lazy { sourceFactory(accountID) }
    }

    @Volatile
    private var scope = AccountScope(initialAccountID)

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
        viewModelScope.launch {
            accountIDs.distinctUntilChanged().collect { switchAccount(it) }
        }
    }

    private fun switchAccount(accountID: String?) {
        if (accountID == scope.accountID) return
        loadJob?.cancel()
        scope = AccountScope(accountID)
        _recap.value = null
        _availableMonths.value = emptyList()
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
        val owner = scope
        viewModelScope.launch {
            val stored = owner.store.availableMonths()
            val completed = RecapWindow.mostRecentCompleted()
            val current = RecapWindow.current()
            val combined = (stored + listOf(completed, current)).distinct().sortedDescending()
            if (owner === scope) _availableMonths.value = combined
        }
    }

    fun load(window: RecapWindow = _selectedMonth.value, forceRegenerate: Boolean = false) {
        loadJob?.cancel()
        _phase.value = RecapPhase.Building
        val owner = scope

        loadJob = viewModelScope.launch {
            try {
                if (!forceRegenerate) {
                    // Only a sealed, complete month is final. A PREVIEW of the
                    // running month (or a partial read) is rebuilt every load.
                    val cached = owner.store.loadRecap(window)?.takeIf { it.sealState.isSealed && !it.isPartial }
                    if (cached != null) {
                        _recap.value = cached
                        _phase.value = RecapPhase.Ready(cached)
                        return@launch
                    }
                }
                executeRecapBuild(owner, window)
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

    private suspend fun executeRecapBuild(owner: AccountScope, window: RecapWindow) {
        val store = owner.store
        val (usages, isPartial) = owner.source.loadUsages(window)
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

        val prevFacts = loadOrFetchPreviousFacts(owner, window)
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

    private suspend fun loadOrFetchPreviousFacts(owner: AccountScope, window: RecapWindow): RecapFacts? {
        val prevWindow = window.previous
        val store = owner.store
        val existing = store.loadReusableFacts(prevWindow)
        if (existing != null) return existing

        val (prevUsages, prevPartial) = owner.source.loadUsages(prevWindow)
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

/** The signed-in uid, re-emitted on every Firebase auth state change. */
internal fun FirebaseAuth.accountIDs(): Flow<String?> = callbackFlow {
    val listener = FirebaseAuth.AuthStateListener { trySend(it.currentUser?.uid) }
    addAuthStateListener(listener)
    awaitClose { removeAuthStateListener(listener) }
}
