using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.Integrations.HomeAssistant.Models;

namespace OpenBurnBar.Integrations.HomeAssistant.Rest;

// Entity-state decoding + media_player projection + Cast detection.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantClient.swift
//   listMediaPlayers(...) projection/sort +
//   extension MediaPlayer { playMediaFeatureBit / entityLooksCastable / bestMatch }.

public static class HomeAssistantStateProjection
{
    /// HA's media_player feature bitmask; only PLAY_MEDIA (1 << 9 = 512 = 0x200)
    /// is checked — the minimum to push a dashboard URL.
    public const int PlayMediaFeatureBit = 0x200;

    /// Decodes an `/api/states` JSON array into entity states. Throws
    /// HomeAssistantClientException.Decoding on malformed input, matching the
    /// Swift `decoder.decode([State].self)` catch path.
    public static IReadOnlyList<HaEntityState> DecodeStates(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw HomeAssistantClientException.Decoding("states response: expected a JSON array");
            }

            var results = new List<HaEntityState>();
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                var entityId = element.TryGetProperty("entity_id", out var e) && e.ValueKind == JsonValueKind.String
                    ? e.GetString() ?? string.Empty
                    : throw HomeAssistantClientException.Decoding("states response: missing entity_id");
                var state = element.TryGetProperty("state", out var s) && s.ValueKind == JsonValueKind.String
                    ? s.GetString() ?? string.Empty
                    : string.Empty;

                var attributes = new Dictionary<string, HaAttributeValue>(StringComparer.Ordinal);
                if (element.TryGetProperty("attributes", out var attrs) && attrs.ValueKind == JsonValueKind.Object)
                {
                    foreach (var prop in attrs.EnumerateObject())
                    {
                        attributes[prop.Name] = HaAttributeValue.FromJson(prop.Value);
                    }
                }

                results.Add(new HaEntityState(entityId, state, attributes));
            }
            return results;
        }
        catch (JsonException ex)
        {
            throw HomeAssistantClientException.Decoding($"states response: {ex.Message}");
        }
    }

    /// Projects the `media_player.*` rows into sorted HaMediaPlayer models,
    /// exactly matching the Swift projection + sort (castable first, then
    /// friendly name case-insensitive ascending).
    public static IReadOnlyList<HaMediaPlayer> ProjectMediaPlayers(IEnumerable<HaEntityState> states)
    {
        var players = states
            .Where(state => state.EntityId.StartsWith("media_player.", StringComparison.Ordinal))
            .Select(state =>
            {
                var friendlyName = state.Attribute("friendly_name")
                    ?? state.EntityId.Replace("media_player.", string.Empty, StringComparison.Ordinal);
                var model = state.Attribute("model_name") ?? state.Attribute("device_model");
                // Parity: Swift does Int(stringValue ?? "0") ?? 0. For a numeric
                // supported_features attribute the string projection is Swift's
                // Double description ("512.0"), which Int(...) rejects -> 0, so on
                // both platforms the bitmask path is inert for numeric attributes
                // and castability falls to the keyword haystack below.
                var supportedFeatures = ParseIntStrict(state.Attribute("supported_features") ?? "0");
                var supportsCast = EntityLooksCastable(state.EntityId, friendlyName, model, supportedFeatures);
                return new HaMediaPlayer(
                    state.EntityId,
                    friendlyName,
                    model,
                    supportsCast,
                    supportedFeatures,
                    state.State);
            })
            .ToList();

        players.Sort((lhs, rhs) =>
        {
            if (lhs.SupportsCast != rhs.SupportsCast)
            {
                // castable (true) sorts before non-castable (false)
                return lhs.SupportsCast ? -1 : 1;
            }
            return string.Compare(lhs.FriendlyName, rhs.FriendlyName, StringComparison.OrdinalIgnoreCase);
        });

        return players;
    }

    /// Parity with Swift `MediaPlayer.entityLooksCastable`.
    public static bool EntityLooksCastable(string entityId, string friendlyName, string? model, int supportedFeatures)
    {
        if ((supportedFeatures & PlayMediaFeatureBit) != 0)
        {
            return true;
        }
        var haystack = string.Join(" ", new[] { entityId, friendlyName, model ?? string.Empty }).ToLowerInvariant();
        string[] needles =
        {
            "nest hub", "chromecast", "google tv", "display",
            "nest mini", "nest audio", "home mini", "home max", "google home",
        };
        return needles.Any(n => haystack.Contains(n, StringComparison.Ordinal));
    }

    /// Parity with Swift `MediaPlayer.bestMatch(in:for:)`. Highest scoring
    /// castable entity whose name matches the discovered Cast device.
    public static HaMediaPlayer? BestMatch(IReadOnlyList<HaMediaPlayer> players, string friendlyName)
    {
        var needle = friendlyName.ToLowerInvariant();
        if (needle.Length == 0)
        {
            return players.FirstOrDefault(p => p.SupportsCast);
        }

        int Score(HaMediaPlayer player)
        {
            var haystack = (player.FriendlyName + " " + player.EntityId + " " + (player.Model ?? string.Empty)).ToLowerInvariant();
            if (haystack == needle)
            {
                return 100;
            }
            if (haystack.Contains(needle, StringComparison.Ordinal))
            {
                return 80;
            }
            if (needle.Contains(haystack, StringComparison.Ordinal))
            {
                return 60;
            }
            var needleWords = TokenSet(needle);
            var hayWords = TokenSet(haystack);
            needleWords.IntersectWith(hayWords);
            return needleWords.Count * 10;
        }

        var castable = players.Where(p => p.SupportsCast).ToList();
        if (castable.Count == 0)
        {
            return null;
        }

        HaMediaPlayer? best = null;
        var bestScore = int.MinValue;
        foreach (var player in castable)
        {
            var score = Score(player);
            if (score > bestScore)
            {
                bestScore = score;
                best = player;
            }
        }

        if (best is not null && bestScore > 0)
        {
            return best;
        }
        return players.FirstOrDefault(p => p.SupportsCast);
    }

    private static HashSet<string> TokenSet(string value)
    {
        var tokens = new HashSet<string>(StringComparer.Ordinal);
        var current = new System.Text.StringBuilder();
        foreach (var ch in value)
        {
            if (char.IsLetterOrDigit(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }
        return tokens;
    }

    /// Parity with Swift `Int(_ text: String)`: accepts only a pure optional-sign
    /// integer literal (no decimal point, no whitespace, no thousands separator),
    /// so "512.0", "", " 5" all fail -> 0, while "512" and "007" parse.
    private static int ParseIntStrict(string text) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : 0;
}
