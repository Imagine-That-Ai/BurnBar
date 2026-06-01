package com.openburnbar.ui.chartstudio

import com.openburnbar.data.hermes.HermesConnectionRecord
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.Flow
import okhttp3.OkHttpClient

private const val BEARER_TOKEN = null // Wire when Relay-mode secret store ships.

/**
 * Streaming bridge between Chart Studio and the user's Hermes endpoint.
 */
class ChartStudioHermesBridge(
    internal val client: OkHttpClient = defaultClient,
    internal val connection: HermesConnectionRecord,
) {
    sealed class Event {
        data class Partial(val text: String) : Event()

        data class Completed(val text: String) : Event()

        data class Failed(val message: String) : Event()
    }

    fun stream(systemPrompt: String, userPrompt: String, model: String = "hermes", temperature: Double = 0.2): Flow<Event> =
        streamEvents(systemPrompt = systemPrompt, userPrompt = userPrompt, model = model, temperature = temperature)

    companion object {
        private val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(120, TimeUnit.SECONDS)
                .build()
        }
    }
}
