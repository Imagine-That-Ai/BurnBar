using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace OpenBurnBar.App.Theme;

/// <summary>
/// Code-behind chokepoint for the brand font families declared in Theme/Typography.xaml.
/// The FontFamily resources live at that dictionary's root (theme-independent), so an
/// Application-level resource lookup resolves them. Falls back to the previous system
/// stacks if a resource is ever missing, so call sites can never crash on font lookup.
/// XAML surfaces should prefer {StaticResource Aurora*Font} directly.
/// </summary>
public static class BrandFonts
{
    /// <summary>JetBrains Mono (bundled) → Cascadia Mono → Consolas.</summary>
    public static FontFamily Mono => Lookup("AuroraMonoFont", "Cascadia Mono, Consolas, Courier New");

    /// <summary>Geist (bundled) → Segoe UI.</summary>
    public static FontFamily Body => Lookup("AuroraBodyFont", "Segoe UI");

    /// <summary>Outfit (bundled) → Segoe UI.</summary>
    public static FontFamily Display => Lookup("AuroraDisplayFont", "Segoe UI");

    private static FontFamily Lookup(string key, string fallback) =>
        Application.Current?.Resources.TryGetValue(key, out var value) == true && value is FontFamily family
            ? family
            : new FontFamily(fallback);
}
