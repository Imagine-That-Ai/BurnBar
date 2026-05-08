import Foundation

// MARK: - Home Assistant Blueprint Installer
//
// Fallback path for users whose HA versions don't expose
// `/api/config/automation/config/<id>` (older installations, restricted
// proxies, advanced YAML-only setups). Instead of asking them to write
// YAML, we hand them a one-tap "My Home Assistant" import link plus a
// downloadable blueprint document with no editing required.
//
// The blueprint is hosted at a stable URL we control. The user clicks
// "Open Home Assistant" → My HA opens their instance → "Add Blueprint"
// dialog appears pre-filled with our YAML → they tap Import → they pick
// their media player entity from a dropdown → done.
//
// Reference:
//   - My Home Assistant: https://my.home-assistant.io/redirect/blueprint_import/
//   - Blueprint format:  https://www.home-assistant.io/docs/blueprint/

struct HomeAssistantBlueprintInstaller: Sendable {

    /// Default hosted blueprint URL. Stored in a constant so changing
    /// the host (e.g. moving from a gist to a repo) is one diff.
    static let defaultBlueprintURL = URL(string: "https://raw.githubusercontent.com/openburnbar/openburnbar/main/integrations/home-assistant/openburnbar_smart_display_recovery.yaml")!

    /// HA's My Home Assistant import-redirect URL.
    static let myHARedirectBaseURL = URL(string: "https://my.home-assistant.io/redirect/blueprint_import/")!

    /// Generates the deep link the user clicks. HA's own blueprint
    /// importer accepts a single `blueprint_url` query parameter.
    static func importDeepLink(blueprintURL: URL = defaultBlueprintURL) -> URL {
        var components = URLComponents(url: myHARedirectBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "blueprint_url", value: blueprintURL.absoluteString)]
        return components.url ?? myHARedirectBaseURL
    }

    /// The actual blueprint YAML payload. We embed it as a string so
    /// `xcodegen`-managed projects don't need a Resources copy phase
    /// for it. The hosted version above is the blueprint of record;
    /// this string is a backup we can paste into HA's UI if hosting
    /// breaks.
    static let blueprintYAML: String = """
blueprint:
  name: OpenBurnBar Smart Display Recovery
  description: >
    Recovers the OpenBurnBar Smart Display when the Mac/iPhone Cast
    path can't reach the device. OpenBurnBar fires the configured
    webhook; this blueprint stops the current cast, waits 3 seconds,
    and restarts the dashboard on the configured media player.
  domain: automation
  source_url: https://github.com/openburnbar/openburnbar/blob/main/integrations/home-assistant/openburnbar_smart_display_recovery.yaml
  input:
    media_player:
      name: Smart Display
      description: The cast-capable media player (Nest Hub, Chromecast, Google TV, etc.) to recover.
      selector:
        entity:
          domain: media_player
    webhook_id:
      name: Webhook ID
      description: >
        The webhook ID OpenBurnBar will call when native Cast fails.
        OpenBurnBar generates a random ID for you in the wizard — paste
        it here verbatim.
      default: openburnbar_cast_recover
      selector:
        text:
mode: restart
max_exceeded: silent
trigger:
  - platform: webhook
    webhook_id: !input webhook_id
    allowed_methods:
      - POST
    local_only: true
variables:
  cast_entity: !input media_player
  fallback_url: "{{ trigger.json.dashboardURL | default('http://homeassistant.local:8123') }}"
action:
  - service: media_player.media_stop
    target:
      entity_id: "{{ cast_entity }}"
  - delay:
      seconds: 3
  - service: media_player.play_media
    target:
      entity_id: "{{ cast_entity }}"
    data:
      media_content_type: video/mp4
      media_content_id: "{{ fallback_url }}"
"""

    /// Materializes the blueprint YAML to a temporary file so the user
    /// can drag it into HA if they prefer. Returns the on-disk URL.
    static func writeYAMLToTemp(_ yaml: String = blueprintYAML) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar_smart_display_recovery.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
