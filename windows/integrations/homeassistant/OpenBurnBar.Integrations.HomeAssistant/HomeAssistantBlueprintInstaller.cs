using System;
using System.IO;

namespace OpenBurnBar.Integrations.HomeAssistant;

// Blueprint fallback installer.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantBlueprintInstaller.swift
//   defaultBlueprintURL / myHARedirectBaseURL / importDeepLink / blueprintYAML /
//   writeYAMLToTemp.
//
// For HA versions without `/api/config/automation/config/<id>`, we hand the user
// a one-tap "My Home Assistant" import link plus a downloadable blueprint.

public static class HomeAssistantBlueprintInstaller
{
    /// Default hosted blueprint URL (single constant so re-hosting is one diff).
    public const string DefaultBlueprintUrl =
        "https://raw.githubusercontent.com/openburnbar/openburnbar/main/integrations/home-assistant/openburnbar_smart_display_recovery.yaml";

    /// HA's My Home Assistant import-redirect URL.
    public const string MyHaRedirectBaseUrl = "https://my.home-assistant.io/redirect/blueprint_import/";

    /// Deep link the user clicks. HA's importer accepts a single `blueprint_url`
    /// query parameter. Parity: Swift `importDeepLink(blueprintURL:)`.
    public static string ImportDeepLink(string blueprintUrl = DefaultBlueprintUrl) =>
        $"{MyHaRedirectBaseUrl}?blueprint_url={Uri.EscapeDataString(blueprintUrl)}";

    /// Materializes the blueprint YAML to a temp file so the user can drag it
    /// into HA. Returns the on-disk path. Parity: Swift `writeYAMLToTemp(_:)`.
    public static string WriteYamlToTemp(string? yaml = null)
    {
        var path = Path.Combine(Path.GetTempPath(), "openburnbar_smart_display_recovery.yaml");
        File.WriteAllText(path, yaml ?? BlueprintYaml);
        return path;
    }

    /// Embedded blueprint of record. Byte-for-byte identical to the Swift
    /// `blueprintYAML` string so the hosted + embedded copies never diverge.
    public const string BlueprintYaml =
        "blueprint:\n" +
        "  name: OpenBurnBar Smart Display Recovery\n" +
        "  description: >\n" +
        "    Recovers the OpenBurnBar Smart Display when the Mac/iPhone Cast\n" +
        "    path can't reach the device. OpenBurnBar fires the configured\n" +
        "    webhook; this blueprint stops the current cast, waits 3 seconds,\n" +
        "    and restarts the dashboard on the configured media player.\n" +
        "  domain: automation\n" +
        "  source_url: https://github.com/openburnbar/openburnbar/blob/main/integrations/home-assistant/openburnbar_smart_display_recovery.yaml\n" +
        "  input:\n" +
        "    media_player:\n" +
        "      name: Smart Display\n" +
        "      description: The cast-capable media player (Nest Hub, Chromecast, Google TV, etc.) to recover.\n" +
        "      selector:\n" +
        "        entity:\n" +
        "          domain: media_player\n" +
        "    webhook_id:\n" +
        "      name: Webhook ID\n" +
        "      description: >\n" +
        "        The webhook ID OpenBurnBar will call when native Cast fails.\n" +
        "        OpenBurnBar generates a random ID for you in the wizard — paste\n" +
        "        it here verbatim.\n" +
        "      default: openburnbar_cast_recover\n" +
        "      selector:\n" +
        "        text:\n" +
        "mode: restart\n" +
        "max_exceeded: silent\n" +
        "trigger:\n" +
        "  - platform: webhook\n" +
        "    webhook_id: !input webhook_id\n" +
        "    allowed_methods:\n" +
        "      - POST\n" +
        "    local_only: true\n" +
        "variables:\n" +
        "  cast_entity: !input media_player\n" +
        "  fallback_url: \"{{ trigger.json.dashboardURL | default('http://homeassistant.local:8123') }}\"\n" +
        "action:\n" +
        "  - service: media_player.media_stop\n" +
        "    target:\n" +
        "      entity_id: \"{{ cast_entity }}\"\n" +
        "  - delay:\n" +
        "      seconds: 3\n" +
        "  - service: media_player.play_media\n" +
        "    target:\n" +
        "      entity_id: \"{{ cast_entity }}\"\n" +
        "    data:\n" +
        "      media_content_type: video/mp4\n" +
        "      media_content_id: \"{{ fallback_url }}\"\n";
}
