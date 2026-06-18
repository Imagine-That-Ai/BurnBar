package com.openburnbar.analytics

/**
 * The transport seam. The real implementation ([AmplitudeTransport]) constructs
 * the Amplitude SDK on [start] — which the recorder calls only after consent —
 * so a pre-consent session never builds the client and makes zero network
 * calls. Tests inject a fake. The recorder never touches the SDK directly, so
 * the consent gate cannot be bypassed.
 *
 * Mirrors `AnalyticsTransporting` from
 * AgentLens/Services/Analytics/AmplitudeTransport.swift and `AnalyticsTransport`
 * from website/src/lib/analytics/recorder.ts.
 */
interface AnalyticsTransport {
    val isStarted: Boolean
    fun start()
    fun stop()
    fun send(name: String, category: String, properties: Map<String, AnalyticsValue>)
    fun setUserId(id: String?)
}
