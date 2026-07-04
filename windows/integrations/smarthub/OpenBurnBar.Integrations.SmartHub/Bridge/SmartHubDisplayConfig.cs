using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// Per-display customization the bridge HTML reads from /state.json.
//
// Parity: OpenBurnBarCore/.../SharedModels/SmartHubDisplayConfig.swift
//   struct SmartHubDisplayConfig + enums Layout/Palette/Theme/Background,
//   including the clamped accessors and hex tables the state renderer emits.

public enum SmartHubDisplayLayout { QuotaCarousel, BigTotal, ProviderGrid, SingleProvider }

public enum SmartHubDisplayPalette { EmberWhimsy, Mercury, ForestSage, Monochrome, Rainbow }

public enum SmartHubDisplayTheme { WarmCharcoal, BotanicalCream, OledBlack, MatchSystem }

public enum SmartHubDisplayBackground { Dashboard, Ambient, PhotoBlend }

public sealed class SmartHubDisplayConfig : IEquatable<SmartHubDisplayConfig>
{
    public SmartHubDisplayLayout Layout { get; set; }
    public SmartHubDisplayPalette Palette { get; set; }
    public SmartHubDisplayTheme Theme { get; set; }
    public SmartHubDisplayBackground Background { get; set; }
    public double Brightness { get; set; }
    public int ScrollSpeedSeconds { get; set; }
    public int RefreshCadenceSeconds { get; set; }
    public IReadOnlyList<string> ProviderIds { get; set; }
    public bool AudibleCue { get; set; }
    public bool IdentifyOnRefresh { get; set; }

    public SmartHubDisplayConfig(
        SmartHubDisplayLayout layout = SmartHubDisplayLayout.QuotaCarousel,
        SmartHubDisplayPalette palette = SmartHubDisplayPalette.EmberWhimsy,
        SmartHubDisplayTheme theme = SmartHubDisplayTheme.WarmCharcoal,
        SmartHubDisplayBackground background = SmartHubDisplayBackground.Dashboard,
        double brightness = 0.85,
        int scrollSpeedSeconds = 8,
        int refreshCadenceSeconds = 5,
        IReadOnlyList<string>? providerIds = null,
        bool audibleCue = false,
        bool identifyOnRefresh = false)
    {
        Layout = layout;
        Palette = palette;
        Theme = theme;
        Background = background;
        Brightness = brightness;
        ScrollSpeedSeconds = scrollSpeedSeconds;
        RefreshCadenceSeconds = refreshCadenceSeconds;
        ProviderIds = providerIds ?? Array.Empty<string>();
        AudibleCue = audibleCue;
        IdentifyOnRefresh = identifyOnRefresh;
    }

    public static SmartHubDisplayConfig Default => new();

    /// Never fully dark — Nest Hub auto-blanks below 20%.
    public double ClampedBrightness => Math.Min(Math.Max(Brightness, 0.2), 1.0);

    public int ClampedScrollSpeed => Math.Min(Math.Max(ScrollSpeedSeconds, 3), 30);

    public int ClampedRefreshCadence => Math.Min(Math.Max(RefreshCadenceSeconds, 3), 60);

    public bool Equals(SmartHubDisplayConfig? other) =>
        other is not null &&
        Layout == other.Layout &&
        Palette == other.Palette &&
        Theme == other.Theme &&
        Background == other.Background &&
        Brightness.Equals(other.Brightness) &&
        ScrollSpeedSeconds == other.ScrollSpeedSeconds &&
        RefreshCadenceSeconds == other.RefreshCadenceSeconds &&
        ProviderIds.SequenceEqual(other.ProviderIds) &&
        AudibleCue == other.AudibleCue &&
        IdentifyOnRefresh == other.IdentifyOnRefresh;

    public override bool Equals(object? obj) => Equals(obj as SmartHubDisplayConfig);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Layout);
        hash.Add(Palette);
        hash.Add(Theme);
        hash.Add(Background);
        hash.Add(Brightness);
        hash.Add(ScrollSpeedSeconds);
        hash.Add(RefreshCadenceSeconds);
        foreach (var id in ProviderIds)
        {
            hash.Add(id);
        }
        hash.Add(AudibleCue);
        hash.Add(IdentifyOnRefresh);
        return hash.ToHashCode();
    }
}

public static class SmartHubDisplayEnums
{
    public static string RawValue(this SmartHubDisplayLayout layout) => layout switch
    {
        SmartHubDisplayLayout.QuotaCarousel => "quotaCarousel",
        SmartHubDisplayLayout.BigTotal => "bigTotal",
        SmartHubDisplayLayout.ProviderGrid => "providerGrid",
        SmartHubDisplayLayout.SingleProvider => "singleProvider",
        _ => "quotaCarousel",
    };

    public static string RawValue(this SmartHubDisplayPalette palette) => palette switch
    {
        SmartHubDisplayPalette.EmberWhimsy => "emberWhimsy",
        SmartHubDisplayPalette.Mercury => "mercury",
        SmartHubDisplayPalette.ForestSage => "forestSage",
        SmartHubDisplayPalette.Monochrome => "monochrome",
        SmartHubDisplayPalette.Rainbow => "rainbow",
        _ => "emberWhimsy",
    };

    public static bool IsRainbow(this SmartHubDisplayPalette palette) => palette == SmartHubDisplayPalette.Rainbow;

    public static string PrimaryHex(this SmartHubDisplayPalette palette) => palette switch
    {
        SmartHubDisplayPalette.EmberWhimsy => "#E07868",
        SmartHubDisplayPalette.Mercury => "#C8BFB5",
        SmartHubDisplayPalette.ForestSage => "#3A7835",
        SmartHubDisplayPalette.Monochrome => "#FFFFFF",
        SmartHubDisplayPalette.Rainbow => "#E40303",
        _ => "#E07868",
    };

    public static string SecondaryHex(this SmartHubDisplayPalette palette) => palette switch
    {
        SmartHubDisplayPalette.EmberWhimsy => "#A294F0",
        SmartHubDisplayPalette.Mercury => "#9A9088",
        SmartHubDisplayPalette.ForestSage => "#7A8572",
        SmartHubDisplayPalette.Monochrome => "#B0B0B0",
        SmartHubDisplayPalette.Rainbow => "#732982",
        _ => "#A294F0",
    };

    public static string RawValue(this SmartHubDisplayTheme theme) => theme switch
    {
        SmartHubDisplayTheme.WarmCharcoal => "warmCharcoal",
        SmartHubDisplayTheme.BotanicalCream => "botanicalCream",
        SmartHubDisplayTheme.OledBlack => "oledBlack",
        SmartHubDisplayTheme.MatchSystem => "matchSystem",
        _ => "warmCharcoal",
    };

    public static (string Top, string Bottom) BackgroundPair(this SmartHubDisplayTheme theme) => theme switch
    {
        SmartHubDisplayTheme.WarmCharcoal => ("#2A221A", "#0E0D0B"),
        SmartHubDisplayTheme.BotanicalCream => ("#EDF0E5", "#D8E2CA"),
        SmartHubDisplayTheme.OledBlack => ("#050505", "#000000"),
        SmartHubDisplayTheme.MatchSystem => ("#2A221A", "#0E0D0B"),
        _ => ("#2A221A", "#0E0D0B"),
    };

    public static string TextHex(this SmartHubDisplayTheme theme) => theme switch
    {
        SmartHubDisplayTheme.WarmCharcoal => "#F0EBE2",
        SmartHubDisplayTheme.BotanicalCream => "#1C2014",
        SmartHubDisplayTheme.OledBlack => "#FFFFFF",
        SmartHubDisplayTheme.MatchSystem => "#F0EBE2",
        _ => "#F0EBE2",
    };

    public static string RawValue(this SmartHubDisplayBackground background) => background switch
    {
        SmartHubDisplayBackground.Dashboard => "dashboard",
        SmartHubDisplayBackground.Ambient => "ambient",
        SmartHubDisplayBackground.PhotoBlend => "photoBlend",
        _ => "dashboard",
    };
}
