package com.openburnbar.analytics

import android.content.Context
import com.amplitude.android.Amplitude
import com.amplitude.android.Configuration
import com.amplitude.core.ServerZone

/**
 * Production [AnalyticsTransport] backed by the Amplitude Android SDK, mirroring
 * AgentLens/Services/Analytics/AmplitudeTransport.swift. The recorder owns
 * lifecycle: [start] is called only after consent is granted, [stop] on revoke.
 *
 * Hardened to macOS parity:
 *  - **autocapture fully disabled** — an empty option set turns off the SDK's
 *    default SESSIONS capture plus app-lifecycle / screen-view / deep-link /
 *    element-interaction capture, so nothing can bypass the consent gate or go
 *    off-taxonomy.
 *  - **IP / geo stripped** via [com.amplitude.android.TrackingOptions]
 *    (disableIpAddress / city / region / carrier / lat-lng / etc.).
 *  - **anonymous device id only** — a random per-install UUID supplied by the
 *    caller, never a hardware id; no `user_id` until authenticated sign-in.
 *
 * With no API key configured it stays dark — the client is never constructed
 * (the recorder's key check guarantees [start] is not even reached, and this
 * class re-checks defensively).
 */
class AmplitudeTransport(
    private val context: Context,
    private val apiKey: String?,
    private val deviceId: String,
    private val serverZone: ServerZone = ServerZone.US,
) : AnalyticsTransport {

    private var amplitude: Amplitude? = null

    override val isStarted: Boolean
        get() = amplitude != null

    override fun start() {
        if (amplitude != null) return
        val key = apiKey
        if (key.isNullOrEmpty()) return // no key → stay dark, never construct the client

        val configuration = Configuration(
            apiKey = key,
            context = context.applicationContext,
            flushQueueSize = FLUSH_QUEUE_SIZE,
            flushIntervalMillis = FLUSH_INTERVAL_MILLIS,
            instanceName = INSTANCE_NAME,
            optOut = false,
            serverZone = serverZone,
            // Empty set = autocapture OFF (no sessions, lifecycle, screen views,
            // deep links, or element interactions). Everything is manual and
            // taxonomy-gated through the recorder.
            autocapture = emptySet(),
            // Strip every geo / device-fingerprinting field the SDK exposes via
            // TrackingOptions. IP off ⇒ no server-side geo enrichment either
            // (macOS parity); city / DMA / lat-lng / carrier removed too.
            trackingOptions = com.amplitude.android.TrackingOptions()
                .disableIpAddress()
                .disableCarrier()
                .disableCity()
                .disableRegion()
                .disableDma()
                .disableLatLng(),
            flushEventsOnClose = true,
            // Anonymous identity only: a random per-install UUID, no advertising
            // id, no Android id, no usage of a hardware identifier.
            deviceId = deviceId,
            // Don't let the SDK reach for the platform advertising/app-set id.
            useAdvertisingIdForDeviceId = false,
            useAppSetIdForDeviceId = false,
        )
        amplitude = Amplitude(configuration)
    }

    override fun stop() {
        // Belt-and-suspenders before teardown, then drop the client and flush nothing.
        amplitude?.let { it.configuration.optOut = true }
        amplitude = null
    }

    override fun send(name: String, category: String, properties: Map<String, AnalyticsValue>) {
        val amp = amplitude ?: return
        val payload = HashMap<String, Any?>(properties.size + 1)
        for ((k, v) in properties) payload[k] = v.anyValue
        payload["event_category"] = category
        amp.track(name, payload)
    }

    override fun setUserId(id: String?) {
        amplitude?.setUserId(id)
    }

    companion object {
        private const val FLUSH_QUEUE_SIZE = 30

        // Android SDK Configuration.flushIntervalMillis is an Int (ms).
        private const val FLUSH_INTERVAL_MILLIS = 30_000
        private const val INSTANCE_NAME = "openburnbar"
    }
}
