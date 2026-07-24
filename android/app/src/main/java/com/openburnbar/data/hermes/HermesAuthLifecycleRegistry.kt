package com.openburnbar.data.hermes

import java.util.concurrent.atomic.AtomicBoolean

/** A process-owned boundary for resources that must not survive a Firebase account transition. */
internal object HermesAuthLifecycleRegistry {
    internal fun interface Resource {
        suspend fun closeForAuthTransition()
    }

    internal class Registration internal constructor(
        internal val id: Long,
        internal val epoch: Long,
    )

    internal class TransitionToken internal constructor(
        internal val epoch: Long,
        internal val released: AtomicBoolean = AtomicBoolean(false),
    )

    private data class Entry(
        val registration: Registration,
        val priority: Int,
        val resource: Resource,
    )

    private val lock = Any()
    private val entries = linkedMapOf<Long, Entry>()
    private var nextID = 0L
    private var epoch = 0L
    private var transitionDepth = 0

    fun register(priority: Int = 0, resource: Resource): Registration = synchronized(lock) {
        val registration = Registration(id = ++nextID, epoch = epoch)
        entries[registration.id] = Entry(registration, priority, resource)
        registration
    }

    fun unregister(registration: Registration) {
        synchronized(lock) { entries.remove(registration.id) }
    }

    fun holdAuthTransitionGate(): TransitionToken = synchronized(lock) {
        transitionDepth += 1
        epoch += 1
        TransitionToken(epoch = epoch)
    }

    suspend fun closeResourcesForTransition(token: TransitionToken) {
        val resources = synchronized(lock) {
            check(!token.released.get()) { "Hermes auth transition gate is already released." }
            entries.values
                .filter { it.registration.epoch < token.epoch }
                .sortedByDescending(Entry::priority)
                .also { stale -> stale.forEach { entries.remove(it.registration.id) } }
                .map(Entry::resource)
        }
        var firstFailure: Throwable? = null
        resources.forEach { resource ->
            runCatching { resource.closeForAuthTransition() }
                .onFailure { error -> if (firstFailure == null) firstFailure = error }
        }
        firstFailure?.let { throw it }
    }

    fun releaseAuthTransitionGate(token: TransitionToken) {
        if (!token.released.compareAndSet(false, true)) return
        synchronized(lock) {
            check(transitionDepth > 0) { "Hermes auth transition gate underflow." }
            transitionDepth -= 1
        }
    }

    fun requireCurrent(registration: Registration) {
        check(
            synchronized(lock) {
                transitionDepth == 0 && registration.epoch == epoch && entries.containsKey(registration.id)
            },
        ) { "Hermes transport was invalidated by an account transition." }
    }

    internal fun activeResourceCountForTests(): Int = synchronized(lock) { entries.size }

    internal fun resetForTests() {
        synchronized(lock) {
            entries.clear()
            epoch = 0L
            transitionDepth = 0
        }
    }
}
