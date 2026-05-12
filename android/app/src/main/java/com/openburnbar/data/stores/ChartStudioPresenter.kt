package com.openburnbar.data.stores

import android.content.Context
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class ChartStudioMode {
    HIDDEN, FULLSCREEN, MINIMIZED
}

class ChartStudioPresenter(context: Context) : ViewModel() {
    companion object {
        private const val FAB_OFFSET_X_KEY = "chartStudio.fabOffset.x"
        private const val FAB_OFFSET_Y_KEY = "chartStudio.fabOffset.y"
    }

    private val prefs = context.applicationContext.getSharedPreferences("chartStudio", Context.MODE_PRIVATE)

    private val _mode = MutableStateFlow(ChartStudioMode.HIDDEN)
    val mode: StateFlow<ChartStudioMode> = _mode.asStateFlow()

    private val _fabOffsetX = MutableStateFlow(prefs.getFloat(FAB_OFFSET_X_KEY, 0f))
    val fabOffsetX: StateFlow<Float> = _fabOffsetX.asStateFlow()

    private val _fabOffsetY = MutableStateFlow(prefs.getFloat(FAB_OFFSET_Y_KEY, -120f))
    val fabOffsetY: StateFlow<Float> = _fabOffsetY.asStateFlow()

    fun present() {
        _mode.value = ChartStudioMode.FULLSCREEN
    }

    fun minimize() {
        if (_mode.value == ChartStudioMode.FULLSCREEN) {
            _mode.value = ChartStudioMode.MINIMIZED
        }
    }

    fun restore() {
        if (_mode.value == ChartStudioMode.MINIMIZED) {
            _mode.value = ChartStudioMode.FULLSCREEN
        }
    }

    fun dismiss() {
        _mode.value = ChartStudioMode.HIDDEN
    }

    fun updateFabOffset(x: Float, y: Float) {
        _fabOffsetX.value = x
        _fabOffsetY.value = y
        prefs.edit()
            .putFloat(FAB_OFFSET_X_KEY, x)
            .putFloat(FAB_OFFSET_Y_KEY, y)
            .apply()
    }
}
