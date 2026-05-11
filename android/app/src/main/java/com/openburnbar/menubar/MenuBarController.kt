package com.openburnbar.menubar

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Source of truth for the BurnBar menu-bar simulation. Whatever provider quota
 * polling layer ends up running keeps this updated; the foreground service,
 * Quick Settings tile, and quick-glance activity all read from here.
 */
data class MenuBarSnapshot(
    val costToday: Double = 0.0,
    val costYesterday: Double = 0.0,
    val totalTokensToday: Long = 0L,
    val sparkline: List<Float> = emptyList(),
    val recentProviders: List<String> = emptyList(),
    val lastUpdated: Long = System.currentTimeMillis(),
    val streaming: Boolean = false
)

object MenuBarController {
    private val _snapshot = MutableStateFlow(MenuBarSnapshot())
    val snapshot: StateFlow<MenuBarSnapshot> = _snapshot

    fun update(snapshot: MenuBarSnapshot) {
        _snapshot.value = snapshot
    }

    fun updateCost(costToday: Double, totalTokensToday: Long) {
        _snapshot.value = _snapshot.value.copy(
            costToday = costToday,
            totalTokensToday = totalTokensToday,
            lastUpdated = System.currentTimeMillis()
        )
    }

    fun formatCost(value: Double): String =
        if (value >= 100.0) "$${"%.0f".format(value)}"
        else "$${"%.2f".format(value)}"
}
