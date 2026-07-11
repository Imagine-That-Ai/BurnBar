// The WinUI render layer for SettingsTab — the piece deliberately LEFT OUT of the
// portable OpenBurnBar.App.Settings library (which carries identity, labels, search,
// and routing). The macOS SettingsTab.icon is an SF Symbol and .accentColor is a
// DesignSystem.Colors.* value; this maps each tab to the Segoe Fluent Icons glyph +
// a dark-shell accent that stands in for those, consistent with Theme/ProviderBrand.cs.

using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Settings;
using Windows.UI;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>Segoe Fluent glyph + accent brush for a <see cref="SettingsTab"/> in the WinUI shell.</summary>
public static class SettingsTabVisuals
{
    /// <summary>Segoe Fluent Icons glyph codepoint standing in for the macOS SF Symbol.</summary>
    public static string Glyph(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => "\uE80F", // Home
        SettingsTab.General => "\uE713", // Setting
        SettingsTab.Updates => "\uE896", // Download
        SettingsTab.Daemon => "\uE756", // CommandPrompt
        SettingsTab.Account => "\uE77B", // Contact
        SettingsTab.Cloud => "\uE753", // Cloud
        SettingsTab.Agents => "\uE99A", // Robot
        SettingsTab.ModelProxy => "\uEC05", // NetworkTower
        SettingsTab.Alerts => "\uEA8F", // Ringer
        SettingsTab.Notifications => "\uE8BD", // Message
        SettingsTab.DevicesAndSync => "\uE895", // Sync
        SettingsTab.TextExpansion => "\uE8D2", // Font
        SettingsTab.Media => "\uE714", // Video
        SettingsTab.DataPrivacy => "\uE72E", // Lock
        SettingsTab.ComputerUse => "\uE7C9", // TouchPointer
        SettingsTab.Pets => "\uEB51", // Heart
        _ => "\uE713",
    };

    /// <summary>Dark-shell accent color roughly mirroring the macOS DesignSystem accent per tab.</summary>
    public static Color AccentColor(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => Hex(0xFA, 0x50, 0x53),          // ember
        SettingsTab.General => Hex(0xFD, 0xC4, 0x2C),        // amber
        SettingsTab.Updates => Hex(0x6A, 0xB0, 0xFF),        // frost
        SettingsTab.Daemon => Hex(0x3C, 0xD6, 0xC0),         // teal
        SettingsTab.Account => Hex(0xC0, 0x84, 0xFC),        // whimsy
        SettingsTab.Cloud => Hex(0xFD, 0xC4, 0x2C),          // hermes aureate
        SettingsTab.Agents => Hex(0xFA, 0x50, 0x53),         // ember
        SettingsTab.ModelProxy => Hex(0xA8, 0x55, 0xF7),     // purple
        SettingsTab.Alerts => Hex(0xE8, 0x61, 0x00),         // blaze
        SettingsTab.Notifications => Hex(0xC0, 0x84, 0xFC),  // whimsy
        SettingsTab.DevicesAndSync => Hex(0x3C, 0xD6, 0xC0), // teal
        SettingsTab.TextExpansion => Hex(0xFD, 0xC4, 0x2C),  // amber
        SettingsTab.Media => Hex(0xC7, 0xCF, 0xDD),          // hermes mercury
        SettingsTab.DataPrivacy => Hex(0x3C, 0xD6, 0xC0),    // teal
        SettingsTab.ComputerUse => Hex(0xE8, 0x61, 0x00),    // blaze
        SettingsTab.Pets => Hex(0xFD, 0xC4, 0x2C),           // amber
        _ => Hex(0xFA, 0x6B, 0x06),
    };

    /// <summary>Accent as a ready-to-bind brush.</summary>
    public static SolidColorBrush AccentBrush(SettingsTab tab) => new(AccentColor(tab));

    private static Color Hex(byte r, byte g, byte b) => Color.FromArgb(0xFF, r, g, b);
}
