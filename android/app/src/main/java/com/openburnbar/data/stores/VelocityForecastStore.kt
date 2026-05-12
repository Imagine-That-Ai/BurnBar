package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.math.max

data class VelocityForecast(
    val dailyBurnRate: Double = 0.0,
    val projectedMonthEnd: Double = 0.0,
    val daysUntilBudgetExhausted: Int? = null,
    val trendDirection: TrendDirection = TrendDirection.FLAT
)

enum class TrendDirection { UP, DOWN, FLAT }

class VelocityForecastStore(
    private val repo: FirestoreRepository = FirestoreRepository()
) : ViewModel() {
    private val _forecast = MutableStateFlow(VelocityForecast())
    val forecast: StateFlow<VelocityForecast> = _forecast.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun load(dailyBudget: Double = 50.0) {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val rollups = repo.fetchRollups()
                val today = rollups.today
                val sevenDays = rollups.sevenDays
                val thirtyDays = rollups.thirtyDays

                val dailyRate = if (sevenDays > 0) sevenDays / 7.0 else today
                val projectedMonthEnd = dailyRate * 30.0

                val daysLeft = if (dailyRate > 0 && dailyBudget > 0) {
                    (dailyBudget / dailyRate).toInt()
                } else null

                val trend = when {
                    today > dailyRate * 1.2 -> TrendDirection.UP
                    today < dailyRate * 0.8 -> TrendDirection.DOWN
                    else -> TrendDirection.FLAT
                }

                _forecast.value = VelocityForecast(
                    dailyBurnRate = dailyRate,
                    projectedMonthEnd = projectedMonthEnd,
                    daysUntilBudgetExhausted = daysLeft,
                    trendDirection = trend
                )
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh(dailyBudget: Double = 50.0) {
        load(dailyBudget)
    }
}
