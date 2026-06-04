package com.openburnbar.data.hermes

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HermesServiceRuntimeSupportTest {
    @Test
    fun probeSelectedRuntimeRecordsHttpModelProbeFailureAsOfflineStateWithoutThrowing() = runTest {
        val connection =
            HermesConnectionRecord(
                id = "direct-test",
                displayName = "Direct test",
                mode = HermesConnectionMode.DIRECT_URL,
                endpointURL = "http://hermes.test",
                status = HermesConnectionStatus.ONLINE,
            )
        val connections = MutableStateFlow(listOf(connection))
        val selectedConnection = MutableStateFlow(connection)
        val runtimeInfo = MutableStateFlow<Map<String, String>>(emptyMap())
        val probeState =
            HermesRuntimeProbeState(
                runtimeInfo = runtimeInfo,
                isReachable = MutableStateFlow(true),
                isConnected = MutableStateFlow(true),
                runtimeErrorText = MutableStateFlow(null),
                isLoadingRuntime = MutableStateFlow(false),
                connections = connections,
                selectedConnectionFlow = selectedConnection,
            )
        val support =
            HermesServiceRuntimeSupport(
                client =
                    OkHttpClient.Builder()
                        .addInterceptor(
                            routeResponses(
                                "/health" to StubResponse(200, """{"model":"fallback-model"}"""),
                                "/v1/models" to StubResponse(401, """{"error":"unauthorized"}"""),
                            ),
                        )
                        .build(),
                selectedConnection = { selectedConnection.value },
                modelState =
                    HermesRuntimeModelState(
                        availableModels = MutableStateFlow(emptyList()),
                        modelOptions = MutableStateFlow(emptyList()),
                        selectedModelID = MutableStateFlow(null),
                    ),
                probeState =
                    probeState,
            )

        support.probeSelectedRuntime("http://hermes.test")

        assertFalse(probeState.isReachable.value)
        assertFalse(probeState.isConnected.value)
        assertFalse(probeState.isLoadingRuntime.value)
        assertEquals(HermesConnectionStatus.OFFLINE, selectedConnection.value.status)
        assertEquals(HermesConnectionStatus.OFFLINE, connections.value.single().status)
        assertTrue(
            "runtime error should preserve the HTTP status class",
            probeState.runtimeErrorText.value?.contains("HTTP 401") == true,
        )
        assertEquals("http://hermes.test", runtimeInfo.value["endpoint"])
        assertTrue(
            "last_error should preserve the HTTP status class",
            runtimeInfo.value["last_error"]?.contains("HTTP 401") == true,
        )
    }

    private data class StubResponse(val code: Int, val body: String)

    private fun routeResponses(vararg routes: Pair<String, StubResponse>): Interceptor {
        val responses = routes.toMap()
        return Interceptor { chain ->
            val stub = responses[chain.request().url.encodedPath] ?: StubResponse(404, "{}")
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(stub.code)
                .message(if (stub.code in 200..299) "OK" else "Error")
                .body(stub.body.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }
}
