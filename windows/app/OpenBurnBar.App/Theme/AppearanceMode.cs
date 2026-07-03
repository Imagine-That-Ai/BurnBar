using Microsoft.UI.Xaml;

namespace OpenBurnBar.App.Theme;

/// <summary>
/// The user's chosen appearance, the Windows analog of the macOS
/// <c>AppearanceMode</c> (<c>AgentLens/Models/Settings/AppearanceMode.swift</c>).
///
/// macOS ships <c>system/light/dark</c>. The Windows port adds
/// <see cref="HighContrast"/> because Win10/11 treats high-contrast as a
/// first-class accessibility appearance (System Settings → Accessibility →
/// Contrast themes), and the master-plan G3 theme axes call for a
/// light/dark/high-contrast/reduced-transparency matrix.
/// </summary>
public enum AppearanceMode
{
    /// <summary>Follow the OS light/dark setting (macOS <c>.system</c>).</summary>
    System,

    /// <summary>Force light (macOS <c>.light</c>).</summary>
    Light,

    /// <summary>Force dark (macOS <c>.dark</c>).</summary>
    Dark,

    /// <summary>
    /// Force a high-contrast presentation: no Mica/Acrylic backdrop, solid
    /// surfaces, and the high-contrast theme dictionary. Has no macOS peer —
    /// it is the Windows accessibility appearance.
    /// </summary>
    HighContrast,
}

/// <summary>Mapping helpers between <see cref="AppearanceMode"/> and WinUI's <see cref="ElementTheme"/>.</summary>
public static class AppearanceModeExtensions
{
    /// <summary>
    /// The WinUI <see cref="ElementTheme"/> a mode requests on the window root.
    /// Mirrors macOS <c>AppearanceMode.colorScheme</c> (<c>.system → nil</c>).
    /// High-contrast keeps the current light/dark base (<see cref="ElementTheme.Default"/>)
    /// and is expressed through the theme dictionary + a disabled backdrop instead.
    /// </summary>
    public static ElementTheme ToElementTheme(this AppearanceMode mode) => mode switch
    {
        AppearanceMode.Light => ElementTheme.Light,
        AppearanceMode.Dark => ElementTheme.Dark,
        AppearanceMode.HighContrast => ElementTheme.Default,
        _ => ElementTheme.Default,
    };

    /// <summary>
    /// Whether a Mica/Acrylic backdrop is allowed for this mode. High-contrast
    /// forbids translucency entirely (parity with the reduced-transparency path).
    /// </summary>
    public static bool AllowsBackdrop(this AppearanceMode mode) => mode != AppearanceMode.HighContrast;

    /// <summary>Round-trips the persisted string form (case-insensitive, defaults to <see cref="AppearanceMode.System"/>).</summary>
    public static AppearanceMode ParseOrSystem(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "light" => AppearanceMode.Light,
        "dark" => AppearanceMode.Dark,
        "highcontrast" or "high-contrast" or "high_contrast" => AppearanceMode.HighContrast,
        _ => AppearanceMode.System,
    };
}
