import Foundation

// MARK: - Home Assistant Recovery Provisioner
//
// Builds and installs the OpenBurnBar recovery automation in a user's
// Home Assistant instance. The shape of the automation:
//
//   - id: openburnbar_smart_display_recovery
//     alias: OpenBurnBar Smart Display Recovery
//     mode: restart
//     trigger:
//       - platform: webhook
//         webhook_id: openburnbar_cast_recover_<secret>
//         allowed_methods: [POST]
//         local_only: true
//     variables:
//       fallback_url: <encoded dashboard URL>
//       cast_entity: media_player.<entity>
//     action:
//       - service: media_player.media_stop
//         target: { entity_id: "{{ cast_entity }}" }
//       - delay: "00:00:03"
//       - service: media_player.play_media
//         target: { entity_id: "{{ cast_entity }}" }
//         data:
//           media_content_type: video/mp4
//           media_content_id: >
//             {{ trigger.json.dashboardURL | default(fallback_url) }}
//
// Why "restart" mode: if Cast also fails the second time and the user
// taps Cast Now again, the automation should cancel any in-flight
// `delay` and start fresh. That's the correct UX for a recovery hook.
//
// Why a fallback URL: HA can also fire this automation on a schedule,
// or via the UI without OpenBurnBar's payload. We always need a sane
// default URL embedded in the automation itself.

struct HomeAssistantRecoveryProvisioner: Sendable {

    static let automationID = "openburnbar_smart_display_recovery"
    static let automationAlias = "OpenBurnBar Smart Display Recovery"

    let client: HomeAssistantClient
    let randomBytes: () -> [UInt8]

    init(
        client: HomeAssistantClient,
        randomBytes: @escaping () -> [UInt8] = HomeAssistantWebhookID.defaultRandomBytes
    ) {
        self.client = client
        self.randomBytes = randomBytes
    }

    /// Builds the automation payload for the REST API. Pure function
    /// so it can be unit tested.
    static func automationPayload(
        webhookID: String,
        mediaPlayerEntityID: String,
        fallbackDashboardURL: URL
    ) -> [String: Any] {
        [
            "id": automationID,
            "alias": automationAlias,
            "description": "Recovers the OpenBurnBar Smart Display when native Cast can't reach it. Installed by OpenBurnBar.",
            "mode": "restart",
            "max_exceeded": "silent",
            "trigger": [
                [
                    "platform": "webhook",
                    "webhook_id": webhookID,
                    "allowed_methods": ["POST"],
                    "local_only": true
                ]
            ],
            "variables": [
                "fallback_url": fallbackDashboardURL.absoluteString,
                "cast_entity": mediaPlayerEntityID
            ],
            "action": [
                [
                    "service": "media_player.media_stop",
                    "target": ["entity_id": mediaPlayerEntityID]
                ],
                [
                    "delay": ["seconds": 3]
                ],
                [
                    "service": "media_player.play_media",
                    "target": ["entity_id": mediaPlayerEntityID],
                    "data": [
                        "media_content_type": "video/mp4",
                        "media_content_id": "{{ trigger.json.dashboardURL if trigger is defined and trigger.json is defined and trigger.json.dashboardURL is defined else fallback_url }}"
                    ]
                ]
            ]
        ]
    }

    /// Installs (or re-installs) the recovery automation. Returns the
    /// updated config with the new webhook ID baked in.
    /// On any HA error we surface it through the existing
    /// `HomeAssistantClient.ClientError` so the wizard can show the
    /// raw cause to the user.
    func install(
        baseURL: URL,
        accessToken: String,
        mediaPlayerEntityID: String,
        mediaPlayerFriendlyName: String,
        fallbackDashboardURL: URL,
        existingWebhookID: String?
    ) async throws -> HomeAssistantConfig {
        let webhookID: String
        if let existing = existingWebhookID, HomeAssistantWebhookID.isOurs(existing) {
            webhookID = existing
        } else {
            webhookID = HomeAssistantWebhookID.generate(randomBytes: randomBytes)
        }

        let payload = Self.automationPayload(
            webhookID: webhookID,
            mediaPlayerEntityID: mediaPlayerEntityID,
            fallbackDashboardURL: fallbackDashboardURL
        )

        try await client.upsertAutomation(
            baseURL: baseURL,
            accessToken: accessToken,
            automationID: Self.automationID,
            payload: payload
        )

        return HomeAssistantConfig(
            baseURL: baseURL,
            mediaPlayerEntityID: mediaPlayerEntityID,
            mediaPlayerFriendlyName: mediaPlayerFriendlyName,
            webhookID: webhookID,
            automationEntityID: "automation.\(Self.automationID)",
            automationInstalled: true,
            lastTestPassed: false,
            lastVerifiedAt: nil,
            setupMode: .rest
        )
    }

    /// Calls the freshly-installed webhook with a synthetic payload.
    /// We deliberately call the webhook itself (not the automation
    /// directly) so we exercise the same path the runtime fallback
    /// uses, end-to-end.
    func runLiveTest(
        config: HomeAssistantConfig,
        dashboardURL: URL
    ) async throws {
        guard let webhookURL = config.webhookURL else {
            throw HomeAssistantClient.ClientError.invalidURL
        }
        let payload: [String: Any] = [
            "source": "openburnbar",
            "action": "cast_recovery",
            "test": true,
            "dashboardURL": dashboardURL.absoluteString,
            "device": [
                "friendlyName": config.mediaPlayerFriendlyName,
                "entityID": config.mediaPlayerEntityID
            ],
            "requestedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        try await client.triggerWebhook(webhookURL, payload: body)
    }
}
