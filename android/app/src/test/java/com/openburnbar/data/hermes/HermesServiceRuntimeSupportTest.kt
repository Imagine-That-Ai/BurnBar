package com.openburnbar.data.hermes

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.ExperimentalForInheritanceCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
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

    /**
     * Race regression: a registry removal that lands between the probe's read of the
     * connection list and its write-back must survive.
     *
     * The probe captures its connection before the HTTP round-trip and rewrites the
     * registry afterwards from the service's IO scope, while `revokeConnection` mutates
     * the same flow from the caller's thread. A plain read-modify-write
     * (`connections.value = connections.value.map { … }`) writes back a list snapshotted
     * before the revoke and resurrects the record the user just removed; the
     * compare-and-set inside `update { }` re-reads and retries, so the revoke wins.
     */
    @Test
    fun probeSelectedRuntimeDoesNotResurrectAConnectionRevokedDuringTheProbe() = runTest {
        val probed = directConnection("direct-test")
        val registry = MutableStateFlow(listOf(HermesConnectionRecord.localDefault, probed))
        val racingRegistry =
            RaceOnNextReadStateFlow(registry) {
                // The registry half of HermesServiceConnectionActions.revokeConnection.
                registry.update { current -> current.filterNot { it.id == probed.id } }
            }
        val support =
            probeSupport(
                connections = racingRegistry,
                selectedConnectionFlow = MutableStateFlow(probed),
                armRaceOnRequest(racingRegistry),
                reachableRoutes(),
            )

        support.probeSelectedRuntime("http://hermes.test")

        assertEquals(
            "a connection revoked mid-probe must not be resurrected by the probe's write-back",
            listOf(HermesConnectionRecord.localDefault.id),
            registry.value.map { it.id },
        )
    }

    /**
     * Race regression: a selection made between the probe's read of the selected
     * connection and its write-back must survive.
     *
     * The pre-fix form read `selectedConnectionFlow.value.id`, compared it to the record
     * it had just probed, and only then assigned — so a `selectConnection` landing in
     * that window was overwritten with the stale probed record. `update { }` re-reads
     * inside the compare-and-set and leaves a changed selection alone.
     */
    @Test
    fun probeSelectedRuntimeKeepsASelectionMadeDuringTheProbe() = runTest {
        val probed = directConnection("direct-test")
        val newlySelected = directConnection("direct-other")
        val selection = MutableStateFlow(probed)
        val racingSelection = RaceOnNextReadStateFlow(selection) { selection.value = newlySelected }
        val support =
            probeSupport(
                connections = MutableStateFlow(listOf(probed, newlySelected)),
                selectedConnectionFlow = racingSelection,
                armRaceOnRequest(racingSelection),
                reachableRoutes(),
            )

        support.probeSelectedRuntime("http://hermes.test")

        assertEquals(
            "a connection selected mid-probe must not be overwritten by the probe's write-back",
            newlySelected,
            selection.value,
        )
    }

    /**
     * A [MutableStateFlow] that runs [mutation] immediately after the next `value` read
     * — and returns the pre-mutation snapshot to that reader.
     *
     * That is the exact window a read-modify-write leaves open for a lost update, and
     * the one `MutableStateFlow.update`'s compare-and-set closes by re-reading and
     * retrying. Driving the interleaving from the flow itself keeps it deterministic;
     * real threads would only reproduce it probabilistically.
     */
    @OptIn(ExperimentalForInheritanceCoroutinesApi::class)
    private class RaceOnNextReadStateFlow<T>(
        private val delegate: MutableStateFlow<T>,
        private val mutation: () -> Unit,
    ) : MutableStateFlow<T> by delegate {
        private var armed = false

        fun arm() {
            armed = true
        }

        override var value: T
            get() {
                val snapshot = delegate.value
                if (armed) {
                    armed = false
                    mutation()
                }
                return snapshot
            }
            set(newValue) {
                delegate.value = newValue
            }
    }

    /**
     * Arms [flow] at the probe's HTTP round-trip — the point where the probe has already
     * captured the connection it is reporting on but has not yet rewritten the registry —
     * so the concurrent mutation lands inside the probe's read-modify-write window.
     */
    private fun armRaceOnRequest(flow: RaceOnNextReadStateFlow<*>): Interceptor = Interceptor { chain ->
        flow.arm()
        chain.proceed(chain.request())
    }

    /** Routes that drive the probe all the way to its ONLINE write-back. */
    private fun reachableRoutes(): Interceptor = routeResponses(
        "/health" to StubResponse(200, """{"model":"hermes-model"}"""),
        "/v1/models" to StubResponse(200, """{"data":[{"id":"hermes-model"}]}"""),
    )

    private fun directConnection(id: String): HermesConnectionRecord = HermesConnectionRecord(
        id = id,
        displayName = id,
        mode = HermesConnectionMode.DIRECT_URL,
        endpointURL = "http://hermes.test",
        status = HermesConnectionStatus.ONLINE,
    )

    /** Builds the probe seam over caller-owned registry flows; [interceptors] apply in order. */
    private fun probeSupport(
        connections: MutableStateFlow<List<HermesConnectionRecord>>,
        selectedConnectionFlow: MutableStateFlow<HermesConnectionRecord>,
        vararg interceptors: Interceptor,
    ): HermesServiceRuntimeSupport {
        val builder = OkHttpClient.Builder()
        interceptors.forEach { builder.addInterceptor(it) }
        return HermesServiceRuntimeSupport(
            client = builder.build(),
            selectedConnection = { selectedConnectionFlow.value },
            modelState =
            HermesRuntimeModelState(
                availableModels = MutableStateFlow(emptyList()),
                modelOptions = MutableStateFlow(emptyList()),
                selectedModelID = MutableStateFlow(null),
            ),
            probeState =
            HermesRuntimeProbeState(
                runtimeInfo = MutableStateFlow<Map<String, String>>(emptyMap()),
                isReachable = MutableStateFlow(true),
                isConnected = MutableStateFlow(true),
                runtimeErrorText = MutableStateFlow(null),
                isLoadingRuntime = MutableStateFlow(false),
                connections = connections,
                selectedConnectionFlow = selectedConnectionFlow,
            ),
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
