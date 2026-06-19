import Foundation
import AmplitudeSwift

/// Production `AnalyticsTransporting` backed by the Amplitude SDK. The recorder
/// owns lifecycle: `start()` is called only after consent is granted, `stop()` on
/// revoke. Autocapture is **fully disabled** (no sessions/lifecycle/screen/clicks
/// can bypass the gate or go off-taxonomy) and geo/device fingerprinting fields
/// are stripped. With no API key configured it stays dark — the client is never
/// constructed.
@MainActor
final class AmplitudeTransport: AnalyticsTransporting {
    private let apiKey: String?
    private let deviceId: String
    private let serverZone: ServerZone
    private var amplitude: Amplitude?

    init(apiKey: String?, deviceId: String, serverZone: ServerZone = .US) {
        self.apiKey = apiKey
        self.deviceId = deviceId
        self.serverZone = serverZone
    }

    var isStarted: Bool { amplitude != nil }

    func start() {
        guard amplitude == nil, let key = apiKey, !key.isEmpty else { return }
        let configuration = Configuration(
            apiKey: key,
            flushQueueSize: 30,
            flushIntervalMillis: 30_000,
            instanceName: "openburnbar",
            optOut: false,
            serverZone: serverZone,
            trackingOptions: TrackingOptions()
                .disableTrackIpAddress()
                .disableTrackCarrier()
                .disableTrackCity()
                .disableTrackDMA()
                .disableTrackIDFV()
                .disableTrackRegion(),
            flushEventsOnClose: true,
            autocapture: []
        )
        let amp = Amplitude(configuration: configuration)
        amp.setDeviceId(deviceId: deviceId) // stable per-install UUID, not a hardware id
        amplitude = amp
    }

    func stop() {
        amplitude?.configuration.optOut = true // belt-and-suspenders before teardown
        amplitude = nil                         // drop the client; flush nothing
    }

    func send(name: String, category: String, properties: [String: AnalyticsValue]) {
        guard let amp = amplitude else { return }
        var payload: [String: Any] = [:]
        for (key, value) in properties { payload[key] = value.anyValue }
        payload["event_category"] = category
        amp.track(eventType: name, eventProperties: payload)
    }

    func setUserId(_ id: String?) {
        amplitude?.setUserId(userId: id)
    }
}
