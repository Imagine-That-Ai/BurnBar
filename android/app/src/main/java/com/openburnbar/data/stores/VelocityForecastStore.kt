package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.openburnbar.data.firebase.FirestoreRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

private const val DOWNTREND_RATIO_THRESHOLD = 0.8
private const val UPTREND_RATIO_THRESHOLD = 1.2
private const val FORECAST_MONTH_DAYS = 30.0
private const val BURN_RATE_WINDOW_DAYS = 7.0
data class VelocityForecast(
    val dailyBurnRate: Double = 0.0,
    val projectedMonthEnd: Double = 0.0,
    val daysUntilBudgetExhausted: Int? = null,
    val trendDirection: TrendDirection = TrendDirection.FLAT,
)

enum class TrendDirection { UP, DOWN, FLAT }

class VelocityForecastStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
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

                val dailyRate = if (sevenDays > 0) sevenDays / BURN_RATE_WINDOW_DAYS else today
                val projectedMonthEnd = dailyRate * FORECAST_MONTH_DAYS

                val daysLeft =
                    if (dailyRate > 0 && dailyBudget > 0) {
                        (dailyBudget / dailyRate).toInt()
                    } else {
                        null
                    }

                val trend =
                    when {
                        today > dailyRate * UPTREND_RATIO_THRESHOLD -> TrendDirection.UP
                        today < dailyRate * DOWNTREND_RATIO_THRESHOLD -> TrendDirection.DOWN
                        else -> TrendDirection.FLAT
                    }

                _forecast.value =
                    VelocityForecast(
                        dailyBurnRate = dailyRate,
                        projectedMonthEnd = projectedMonthEnd,
                        daysUntilBudgetExhausted = daysLeft,
                        trendDirection = trend,
                    )
            } catch (e: FirebaseException) {
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
