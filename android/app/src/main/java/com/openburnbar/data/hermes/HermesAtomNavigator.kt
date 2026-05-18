package com.openburnbar.data.hermes

import android.util.Log

/**
 * Abstract dispatcher for atom-tap navigation. The Compose surface
 * (chat surface, atom chip, project memory rail) calls `open(atom)`
 * when the user taps an atom; the implementation pushes onto the
 * Navigation stack, presents a sheet, or switches tabs as appropriate.
 *
 * 1:1 port of the Swift `HermesAtomNavigator` protocol in
 * `OpenBurnBarCore/Hermes/HermesAtomNavigator.swift`. Implementations
 * should be idempotent and safe to call from any state.
 */
interface HermesAtomNavigator {
    fun open(atom: HermesAtom)
}

/**
 * Safe default navigator used when no concrete one has been injected
 * yet. Logs so missed wiring is visible during development.
 */
class NoopHermesAtomNavigator : HermesAtomNavigator {
    override fun open(atom: HermesAtom) {
        Log.i(TAG, "Atom tapped but no navigator is wired: $atom")
    }

    private companion object {
        private const val TAG = "HermesAtomNavigator"
    }
}
