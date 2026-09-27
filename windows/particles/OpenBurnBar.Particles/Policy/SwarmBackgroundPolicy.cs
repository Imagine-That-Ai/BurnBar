// PORTED (portable, unit-tested) from:
//   OpenBurnBarMobile/Models/SwarmBackgroundPreferences.swift
//
// Dependency-free except System.Text.Json (in-box for net8.0). The gate-policy
// layer of the swarm background: the render-plan power policy, the
// decorative-effects gate, the visibility lattice, and the persisted-preference
// codec. The particle simulation and substrate painters consume the resolved
// plan; this file owns only the gating decisions so Windows resolves the exact
// same plan (and the exact same persisted defaults) as iOS for the same inputs.
//
// Wire values (location/condition raw strings, preference JSON keys, glyph
// display-name tokens) are byte-compatible with the Swift `Codable` forms.
// Glyph tokens stay as display-name strings (rather than referencing the
// Settings `AgentProvider` enum) so this renderer core keeps zero project
// references; the token table is cross-checked against the Settings catalog by
// OpenBurnBar.Particles.Tests.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace OpenBurnBar.Particles.Policy;

/// <summary>Where the swarm background may render. Swift <c>SwarmBackgroundLocation</c>.</summary>
public enum SwarmBackgroundLocation
{
    Disabled,
    AgentsTab,
    Everywhere,
}

/// <summary>When the swarm background may render. Swift <c>SwarmBackgroundCondition</c>.</summary>
public enum SwarmBackgroundCondition
{
    Always,
    PowerConnected,
    WifiOnly,
}

/// <summary>Background prominence lattice. Swift <c>MobileBackgroundVisibility</c>.</summary>
public enum MobileBackgroundVisibility
{
    Prominent,
    Subtle,
    Obscured,
    Hidden,
}

/// <summary>Render-plan mode. Swift <c>SwarmBackgroundRenderPlan.Mode</c>.</summary>
public enum SwarmRenderMode
{
    Live,
    StaticBackdrop,
    DisabledFallback,
}

/// <summary>Wire values + lattice math for the swarm gate enums, parity with Swift.</summary>
public static class SwarmGateMetadata
{
    /// <summary>The persisted raw value (Swift <c>rawValue</c>).</summary>
    public static string RawValue(this SwarmBackgroundLocation location) => location switch
    {
        SwarmBackgroundLocation.Disabled => "Disabled",
        SwarmBackgroundLocation.AgentsTab => "Agents Tab Only",
        SwarmBackgroundLocation.Everywhere => "Everywhere",
        _ => throw new ArgumentOutOfRangeException(nameof(location), location, null),
    };

    /// <summary>Parse a persisted raw value, or <c>null</c> if unknown.</summary>
    public static SwarmBackgroundLocation? LocationFromRawValue(string? raw)
    {
        foreach (SwarmBackgroundLocation location in Enum.GetValues(typeof(SwarmBackgroundLocation)))
        {
            if (string.Equals(location.RawValue(), raw, StringComparison.Ordinal))
            {
                return location;
            }
        }

        return null;
    }

    /// <summary>The persisted raw value (Swift <c>rawValue</c>).</summary>
    public static string RawValue(this SwarmBackgroundCondition condition) => condition switch
    {
        SwarmBackgroundCondition.Always => "Always",
        SwarmBackgroundCondition.PowerConnected => "Power Connected Only",
        SwarmBackgroundCondition.WifiOnly => "Wi-Fi Only",
        _ => throw new ArgumentOutOfRangeException(nameof(condition), condition, null),
    };

    /// <summary>Parse a persisted raw value, or <c>null</c> if unknown.</summary>
    public static SwarmBackgroundCondition? ConditionFromRawValue(string? raw)
    {
        foreach (SwarmBackgroundCondition condition in Enum.GetValues(typeof(SwarmBackgroundCondition)))
        {
            if (string.Equals(condition.RawValue(), raw, StringComparison.Ordinal))
            {
                return condition;
            }
        }

        return null;
    }

    private static int RestrictionRank(this MobileBackgroundVisibility visibility) => visibility switch
    {
        MobileBackgroundVisibility.Prominent => 0,
        MobileBackgroundVisibility.Subtle => 1,
        MobileBackgroundVisibility.Obscured => 2,
        MobileBackgroundVisibility.Hidden => 3,
        _ => throw new ArgumentOutOfRangeException(nameof(visibility), visibility, null),
    };

    /// <summary>
    /// Swift <c>MobileBackgroundVisibility.constrained(by:)</c>: the more
    /// restrictive of the two wins. Ties resolve to <paramref name="self"/>.
    /// </summary>
    public static MobileBackgroundVisibility Constrained(
        this MobileBackgroundVisibility self,
        MobileBackgroundVisibility inherited) =>
        self.RestrictionRank() >= inherited.RestrictionRank() ? self : inherited;
}

/// <summary>
/// Resolved render plan. Swift <c>SwarmBackgroundRenderPlan</c> + its four
/// canonical plans. A record struct so plans compare by value.
/// </summary>
public readonly record struct SwarmBackgroundRenderPlan(
    SwarmRenderMode Mode,
    double? MaxFrameRate,
    double ParticleScale,
    double MotionSpeedMultiplierScale,
    bool AllowsAutoCycling,
    bool AllowsSparkles,
    bool IsBatteryThrottled)
{
    public static readonly SwarmBackgroundRenderPlan ProminentLive = new(
        SwarmRenderMode.Live, 30, 1.0, 1.0, true, true, false);

    public static readonly SwarmBackgroundRenderPlan SubtleLive = new(
        SwarmRenderMode.Live, 15, 0.45, 0.55, false, false, true);

    public static readonly SwarmBackgroundRenderPlan StaticBackdrop = new(
        SwarmRenderMode.StaticBackdrop, null, 0, 0, false, false, true);

    public static readonly SwarmBackgroundRenderPlan DisabledFallback = new(
        SwarmRenderMode.DisabledFallback, null, 0, 0, false, false, false);
}

/// <summary>Swift <c>SwarmBackgroundPowerPolicy</c>.</summary>
public static class SwarmBackgroundPowerPolicy
{
    /// <summary>
    /// Swift <c>SwarmBackgroundPowerPolicy.resolve</c>: the guard chain is
    /// order sensitive — location → condition → scene/visibility →
    /// motion/obscured → low-power — and each early return is a distinct
    /// plan. Keep in lockstep.
    /// </summary>
    public static SwarmBackgroundRenderPlan Resolve(
        SwarmBackgroundLocation location,
        bool conditionMet,
        MobileBackgroundVisibility requestedVisibility,
        bool scenePhaseActive,
        bool isLowPowerModeEnabled,
        bool reduceMotion)
    {
        if (location == SwarmBackgroundLocation.Disabled)
        {
            return SwarmBackgroundRenderPlan.DisabledFallback;
        }

        if (!conditionMet)
        {
            return SwarmBackgroundRenderPlan.StaticBackdrop;
        }

        if (!scenePhaseActive || requestedVisibility == MobileBackgroundVisibility.Hidden)
        {
            return SwarmBackgroundRenderPlan.StaticBackdrop;
        }

        if (reduceMotion || requestedVisibility == MobileBackgroundVisibility.Obscured)
        {
            return SwarmBackgroundRenderPlan.StaticBackdrop;
        }

        if (isLowPowerModeEnabled)
        {
            return requestedVisibility == MobileBackgroundVisibility.Prominent
                ? SwarmBackgroundRenderPlan.SubtleLive
                : SwarmBackgroundRenderPlan.StaticBackdrop;
        }

        return requestedVisibility == MobileBackgroundVisibility.Prominent
            ? SwarmBackgroundRenderPlan.ProminentLive
            : SwarmBackgroundRenderPlan.SubtleLive;
    }
}

/// <summary>Swift <c>MobileDecorativeRenderPolicy</c>.</summary>
public static class MobileDecorativeRenderPolicy
{
    /// <summary>
    /// Swift <c>allowsLiveEffects</c>: live decorative effects run only while
    /// the scene is active and the background is at least subtle (neither
    /// hidden nor obscured).
    /// </summary>
    public static bool AllowsLiveEffects(
        MobileBackgroundVisibility visibility,
        bool scenePhaseActive) =>
        scenePhaseActive &&
            visibility != MobileBackgroundVisibility.Hidden &&
            visibility != MobileBackgroundVisibility.Obscured;
}

/// <summary>Pure decision core of Swift <c>SwarmEnvironmentMonitor.meetsCondition</c>.</summary>
public static class SwarmEnvironmentConditionEvaluator
{
    /// <summary>
    /// The platform monitor owns the sensors; the gate owns the truth table.
    /// </summary>
    public static bool MeetsCondition(
        SwarmBackgroundCondition condition,
        bool isPowerConnected,
        bool isWifiConnected) => condition switch
    {
        SwarmBackgroundCondition.Always => true,
        SwarmBackgroundCondition.PowerConnected => isPowerConnected,
        SwarmBackgroundCondition.WifiOnly => isWifiConnected,
        _ => throw new ArgumentOutOfRangeException(nameof(condition), condition, null),
    };
}

/// <summary>
/// Persisted swarm preferences. Swift <c>SwarmBackgroundPreferences</c>.
/// Glyphs are display-name tokens (the Swift <c>Codable</c> wire form).
/// </summary>
public sealed class SwarmBackgroundPreferences : IEquatable<SwarmBackgroundPreferences>
{
    /// <summary>Swift <c>userDefaultsKey</c>.</summary>
    public const string UserDefaultsKey = "swarmBackgroundPreferencesV2";

    /// <summary>
    /// Canonical glyph-token table: Swift <c>AgentProvider.swarmGlyphProviders</c>
    /// display names in order. Cross-checked against the Settings catalog by
    /// <c>SwarmBackgroundPolicyTests.GlyphTokens_MatchSettingsCatalog</c>.
    /// </summary>
    public static readonly IReadOnlyList<string> DefaultGlyphTokens =
        new[]
        {
            "Factory",
            "Claude Code",
            "Codex",
            "OpenCode",
            "OpenClaw",
            "OpenClaude",
            "OMP",
            "Hermes",
            "Prime Agent",
            "Gemini CLI",
            "Junie",
            "Antigravity",
            "OpenAI",
            "OpenBurnBar",
            "DeepSeek",
            "MiniMax",
            "Zai",
            "xAI",
            "MiMo",
            "Cursor",
            "Copilot",
            "Kimi",
            "Aider",
            "Cline",
            "Kilo Code",
            "Roo Code",
            "Forge",
            "Augment",
            "Pi Agent",
            "Goose",
            "Ollama",
            "Windsurf",
            "Devin",
            "Warp",
            "Cursor Agent",
            "Muse",
            "fx",
        };

    /// <summary>Swift <c>defaultJSON</c>: the JSON encoding of defaults.</summary>
    public static readonly string DefaultJson = new SwarmBackgroundPreferences().ToJsonString();

    public SwarmBackgroundLocation Location { get; }
    public SwarmBackgroundCondition Condition { get; }
    public IReadOnlyList<string> SelectedGlyphs { get; }
    public bool IsAvatarEnabled { get; }
    public bool IsBrandTextEnabled { get; }
    public bool ExcludeBrandShapes { get; }

    public SwarmBackgroundPreferences(
        SwarmBackgroundLocation location = SwarmBackgroundLocation.Disabled,
        SwarmBackgroundCondition condition = SwarmBackgroundCondition.Always,
        IReadOnlyList<string>? selectedGlyphs = null,
        bool isAvatarEnabled = true,
        bool isBrandTextEnabled = true,
        bool excludeBrandShapes = false)
    {
        Location = location;
        Condition = condition;
        SelectedGlyphs = selectedGlyphs ?? DefaultGlyphTokens;
        IsAvatarEnabled = isAvatarEnabled;
        IsBrandTextEnabled = isBrandTextEnabled;
        ExcludeBrandShapes = excludeBrandShapes;
    }

    /// <summary>
    /// Swift <c>SwarmBackgroundPreferences.from(jsonString:)</c>: a missing key
    /// (or an explicit null, per <c>decodeIfPresent</c>) falls back to that
    /// field's default, but any structural failure — malformed JSON, a mistyped
    /// value, an unknown location/condition wire value, or an unrecognized
    /// glyph token — discards the whole payload and returns defaults.
    /// </summary>
    public static SwarmBackgroundPreferences From(string jsonString)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(jsonString);
        }
        catch (Exception ex) when (ex is JsonException || ex is ArgumentException)
        {
            return new SwarmBackgroundPreferences();
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return new SwarmBackgroundPreferences();
            }

            return DecodeObject(document.RootElement) ?? new SwarmBackgroundPreferences();
        }
    }

    public string ToJsonString()
    {
        using System.IO.MemoryStream stream = new();
        using (Utf8JsonWriter writer = new(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("location", Location.RawValue());
            writer.WriteString("condition", Condition.RawValue());
            writer.WriteStartArray("selectedGlyphs");
            foreach (string glyph in SelectedGlyphs)
            {
                writer.WriteStringValue(glyph);
            }

            writer.WriteEndArray();
            writer.WriteBoolean("isAvatarEnabled", IsAvatarEnabled);
            writer.WriteBoolean("isBrandTextEnabled", IsBrandTextEnabled);
            writer.WriteBoolean("excludeBrandShapes", ExcludeBrandShapes);
            writer.WriteEndObject();
        }

        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    public bool Equals(SwarmBackgroundPreferences? other)
    {
        if (other is null)
        {
            return false;
        }

        return Location == other.Location &&
            Condition == other.Condition &&
            SelectedGlyphs.SequenceEqual(other.SelectedGlyphs) &&
            IsAvatarEnabled == other.IsAvatarEnabled &&
            IsBrandTextEnabled == other.IsBrandTextEnabled &&
            ExcludeBrandShapes == other.ExcludeBrandShapes;
    }

    public override bool Equals(object? obj) => Equals(obj as SwarmBackgroundPreferences);

    public override int GetHashCode() => HashCode.Combine(
        Location, Condition, IsAvatarEnabled, IsBrandTextEnabled, ExcludeBrandShapes);

    private static bool TryField(JsonElement root, string name, out JsonElement field)
    {
        field = default;
        if (!root.TryGetProperty(name, out JsonElement found))
        {
            return false;
        }

        if (found.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return false;
        }

        field = found;
        return true;
    }

    private static SwarmBackgroundPreferences? DecodeObject(JsonElement root)
    {
        SwarmBackgroundLocation location = SwarmBackgroundLocation.Disabled;
        if (TryField(root, "location", out JsonElement locationField))
        {
            if (locationField.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            if (SwarmGateMetadata.LocationFromRawValue(locationField.GetString()) is not SwarmBackgroundLocation parsed)
            {
                return null;
            }

            location = parsed;
        }

        SwarmBackgroundCondition condition = SwarmBackgroundCondition.Always;
        if (TryField(root, "condition", out JsonElement conditionField))
        {
            if (conditionField.ValueKind != JsonValueKind.String ||
                SwarmGateMetadata.ConditionFromRawValue(conditionField.GetString()) is not SwarmBackgroundCondition parsedCondition)
            {
                return null;
            }

            condition = parsedCondition;
        }

        IReadOnlyList<string> selectedGlyphs = DefaultGlyphTokens;
        if (TryField(root, "selectedGlyphs", out JsonElement glyphsField))
        {
            if (glyphsField.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            List<string> glyphs = new();
            foreach (JsonElement item in glyphsField.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    return null;
                }

                string token = item.GetString() ?? string.Empty;
                if (!DefaultGlyphTokens.Contains(token))
                {
                    return null;
                }

                glyphs.Add(token);
            }

            selectedGlyphs = glyphs;
        }

        if (!TryDecodeBool(root, "isAvatarEnabled", defaultValue: true, out bool isAvatarEnabled) ||
            !TryDecodeBool(root, "isBrandTextEnabled", defaultValue: true, out bool isBrandTextEnabled) ||
            !TryDecodeBool(root, "excludeBrandShapes", defaultValue: false, out bool excludeBrandShapes))
        {
            return null;
        }

        return new SwarmBackgroundPreferences(
            location, condition, selectedGlyphs,
            isAvatarEnabled, isBrandTextEnabled, excludeBrandShapes);
    }

    private static bool TryDecodeBool(JsonElement root, string name, bool defaultValue, out bool value)
    {
        value = defaultValue;
        if (!TryField(root, name, out JsonElement field))
        {
            return true;
        }

        if (field.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }

        value = field.GetBoolean();
        return true;
    }
}

/// <summary>
/// What the render host should do on one compositor tick, given the resolved
/// plan. Pure and portable so the WinUI host (<c>SwarmCanvasHost</c>, which
/// only Windows/CI exercises live) stays a thin caller over tested logic.
/// </summary>
public enum SwarmHostFrameAction
{
    /// <summary>Render this tick: live and inside the frame budget.</summary>
    Render,

    /// <summary>Skip this tick: live but throttled inside the frame budget.</summary>
    SkipThrottled,

    /// <summary>Skip this tick: disabled, or static and already rendered.</summary>
    SkipSuppressed,
}

/// <summary>
/// Maps a resolved <see cref="SwarmBackgroundRenderPlan"/> onto host tick
/// behavior. The host owns sensors, prefs, and the canvas; this owns the
/// mode → frame-budget decision so every host honors the same gate.
/// </summary>
public static class SwarmHostRenderGate
{
    /// <summary>
    /// Legacy loop floor when a live plan carries no fps cap (the host's
    /// historical ~33fps throttle).
    /// </summary>
    public static readonly TimeSpan FallbackFrameInterval = TimeSpan.FromMilliseconds(30);

    /// <summary>Frame budget for a live plan: its fps cap, or the legacy floor.</summary>
    public static TimeSpan FrameInterval(SwarmBackgroundRenderPlan plan)
    {
        if (plan.Mode == SwarmRenderMode.Live &&
            plan.MaxFrameRate is double fps &&
            fps > 0)
        {
            return TimeSpan.FromSeconds(1.0 / fps);
        }

        return FallbackFrameInterval;
    }

    /// <summary>
    /// Decides one host tick. Disabled plans never render; static plans render
    /// exactly one frame per plan (the host passes whether it already rendered
    /// this plan and resets that flag when the plan changes); live plans render
    /// once the frame budget elapses.
    /// </summary>
    public static SwarmHostFrameAction DecideAction(
        SwarmBackgroundRenderPlan plan,
        TimeSpan sinceLastFrame,
        bool staticFrameRendered)
    {
        return plan.Mode switch
        {
            SwarmRenderMode.DisabledFallback => SwarmHostFrameAction.SkipSuppressed,
            SwarmRenderMode.StaticBackdrop => staticFrameRendered
                ? SwarmHostFrameAction.SkipSuppressed
                : SwarmHostFrameAction.Render,
            _ => sinceLastFrame < FrameInterval(plan)
                ? SwarmHostFrameAction.SkipThrottled
                : SwarmHostFrameAction.Render,
        };
    }
}
