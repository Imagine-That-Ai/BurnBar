using System;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Theme;

// MARK: - Liquid Glass (Windows) — Mica / Acrylic shim
//
// Windows mirror of `AgentLens/Theme/LiquidGlass.swift` (macOS 26+ Liquid Glass
// adapters). This is the single glass CHOKEPOINT for the Windows port
// (Phase 3 · W6 · W6-DS-GLASS): every surface that leaned on `.liquidGlassSurface`,
// `.liquidGlassInteractive`, `.liquidGlassCircleButton`, `LiquidGlassGroup`, or the
// behind-window blend routes through the vocabulary here so the transparency
// preference stays honored app-wide and the accepted drift is documented in ONE
// place. Keep this file in lockstep with the Swift original when the vocabulary grows.
//
// Vocabulary parity (Swift member -> C# member):
//   • View.liquidGlassSurface(...)      -> LiquidGlass.Surface attached property
//                                          + `LiquidGlassSurfaceStyle` (Theme/LiquidGlass.xaml)
//   • View.liquidGlassInteractive(...)  -> LiquidGlass.Interactive attached property
//                                          + `LiquidGlassInteractiveStyle` (PointerOver/Pressed
//                                          VisualStates)
//   • View.liquidGlassCircleButton(...) -> LiquidGlass.CircleButtonDiameter attached property
//                                          + `LiquidGlassCircleButtonStyle`
//   • liquidGlassEffect(_:in:)          -> LiquidGlassStyle (fluent) + LiquidGlass.ResolveBackdropKind
//   • LiquidGlassGroup                  -> LiquidGlassGroup (no-op ContentControl)
//   • LiquidGlassTransparency           -> LiquidGlassTransparency (pure math, exact port)
//   • LiquidGlassWindowBlend            -> LiquidGlassWindowBlend (-> DesktopAcrylicBackdrop)
//
// ============================ NOTES — accepted drift (R7) ============================
// macOS 26 "Liquid Glass" is a CONTENT-refracting material: a glass plate samples and
// bends whatever is *directly behind the element inside the app* (glass-over-content,
// glass-over-glass when grouped, and an interactive lensing highlight that tracks the
// pointer). Windows has no in-app content-refraction primitive. The closest primitives
// are the SYSTEM BACKDROPS — MicaBackdrop and DesktopAcrylicBackdrop — which blur only
// the WINDOW/DESKTOP behind the whole window, plus the in-app `AcrylicBrush` which blurs
// only what is composed behind the *window* (again not app content behind a specific
// card). So the R7 accepted drift, gated at G3 against macOS goldens, is:
//   1. No content refraction — a glass card does NOT bend the app content behind it,
//      only the window/desktop backdrop. Per-surface parity is therefore APPROXIMATE.
//   2. No glass-over-glass — `LiquidGlassGroup` is a NO-OP here (the macOS
//      `GlassEffectContainer` exists solely to give grouped glass a shared sampling
//      region so glass can sample glass; with no sampling there is nothing to share).
//   3. No interactive lensing — `LiquidGlassInteractive`'s pointer feedback is an
//      opacity/overlay VisualState transition, not a light-bending lens highlight.
// Everything else — the transparency preference `t`, the Reduce-Transparency clamp, the
// contentSurfacesEnabled solid fallback, and the frost/clear scrims — is reproduced
// EXACTLY (see `LiquidGlassTransparency`, a byte-for-byte port of the Swift math).
// ====================================================================================

// NOTE: The parity-critical transparency math lives in the dependency-free companion
// file Theme/LiquidGlassTransparency.cs (a byte-for-byte port of the Swift enum). This
// file holds the WinUI adapters that consume it. The OS-capability default for the
// content-surfaces toggle is `LiquidGlass.DefaultContentSurfacesEnabled` below.

// MARK: - Backdrop kind

/// <summary>
/// The system backdrop a given effective transparency resolves to. Mirrors the branch
/// taken inside the Swift modifiers (<c>Glass = .regular | .clear</c> + the material
/// fallback), remapped to the Windows backdrop vocabulary.
/// </summary>
public enum LiquidGlassBackdropKind
{
    /// <summary>Content surfaces disabled (or unsupported OS) — paint a solid brush.
    /// Swift: the <c>#available … else</c> branch with fallback material at full opacity.</summary>
    Solid,

    /// <summary>Neutral (<c>t == 0</c>) — MicaBackdrop, <c>MicaKind.Base</c>.
    /// Swift: <c>Glass.regular</c> at neutral.</summary>
    MicaBase,

    /// <summary>Frostier (<c>t &lt; 0</c>) — MicaBackdrop, <c>MicaKind.BaseAlt</c>, plus the
    /// frost scrim. Swift: <c>Glass.regular</c> + the <c>.thickMaterial</c> frost scrim.</summary>
    MicaBaseAlt,

    /// <summary>Clearer (<c>t &gt; 0</c>) — DesktopAcrylicBackdrop (more see-through than
    /// Mica), plus the clear-bridge scrim. Swift: <c>Glass.clear</c> + the bridge scrim.</summary>
    Acrylic,
}

// MARK: - Runtime environment (the @AppStorage + @Environment inputs)

/// <summary>
/// The three runtime inputs the Swift modifiers read — the stored transparency
/// preference, the content-surfaces toggle, and the accessibility Reduce-Transparency
/// flag — gathered into one object. On macOS these arrive via
/// <c>@AppStorage(storageKey)</c>, <c>@AppStorage(contentSurfacesEnabledKey)</c> and
/// <c>@Environment(\.accessibilityReduceTransparency)</c>; here they are backed by a
/// pluggable <see cref="ILiquidGlassPreferenceStore"/> (mirroring UserDefaults) and
/// <see cref="UISettings.AdvancedEffectsEnabled"/> (mirroring Reduce Transparency).
/// </summary>
public sealed class LiquidGlassEnvironment
{
    private static readonly UISettings SharedUiSettings = new();
    private readonly ILiquidGlassPreferenceStore _store;

    /// <summary>The process-wide environment used by the attached properties and window
    /// backdrop helper. Settings surfaces mutate this; changes take effect on next apply.</summary>
    public static LiquidGlassEnvironment Current { get; set; } =
        new LiquidGlassEnvironment(new InMemoryPreferenceStore());

    public LiquidGlassEnvironment(ILiquidGlassPreferenceStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
    }

    /// <summary>Raw, unclamped stored preference. Swift: <c>@AppStorage(storageKey) rawTransparency</c>.</summary>
    public double RawTransparency
    {
        get => _store.GetDouble(LiquidGlassTransparency.StorageKey, 0);
        set => _store.SetDouble(LiquidGlassTransparency.StorageKey, value);
    }

    /// <summary>Whether content-level surfaces use glass. Swift:
    /// <c>@AppStorage(contentSurfacesEnabledKey) contentSurfacesEnabled</c> with the same default.</summary>
    public bool ContentSurfacesEnabled
    {
        get => _store.GetBool(
            LiquidGlassTransparency.ContentSurfacesEnabledKey,
            LiquidGlass.DefaultContentSurfacesEnabled);
        set => _store.SetBool(LiquidGlassTransparency.ContentSurfacesEnabledKey, value);
    }

    /// <summary>
    /// The accessibility Reduce-Transparency state. On Windows, transparency effects are
    /// governed by Settings &gt; Personalization &gt; Colors &gt; Transparency effects and
    /// surfaced as <see cref="UISettings.AdvancedEffectsEnabled"/> (true = effects ON).
    /// Reduce-Transparency is therefore the INVERSE. Mirrors the macOS
    /// <c>accessibilityReduceTransparency</c> environment value.
    /// </summary>
    public bool ReduceTransparency
    {
        get
        {
            try
            {
                return !SharedUiSettings.AdvancedEffectsEnabled;
            }
            catch (Exception)
            {
                // Headless/test hosts without a UISettings provider: treat as effects-on.
                return false;
            }
        }
    }

    /// <summary>The resolved, accessibility-clamped transparency. Swift:
    /// <c>LiquidGlassTransparency.effective(rawTransparency, reduceTransparency:)</c>.</summary>
    public double EffectiveTransparency =>
        LiquidGlassTransparency.Effective(RawTransparency, ReduceTransparency);
}

/// <summary>Persistence seam mirroring macOS <c>UserDefaults</c> — the shim stores the
/// same two keys (<see cref="LiquidGlassTransparency.StorageKey"/> /
/// <see cref="LiquidGlassTransparency.ContentSurfacesEnabledKey"/>). Wiring this to a
/// concrete registry / settings-file store is a Settings-surface follow-up (W7); the
/// default is process-local in-memory so the shim works standalone and in tests.</summary>
public interface ILiquidGlassPreferenceStore
{
    double GetDouble(string key, double defaultValue);
    void SetDouble(string key, double value);
    bool GetBool(string key, bool defaultValue);
    void SetBool(string key, bool value);
}

/// <summary>Default in-memory preference store (UserDefaults analog).</summary>
public sealed class InMemoryPreferenceStore : ILiquidGlassPreferenceStore
{
    private readonly System.Collections.Generic.Dictionary<string, object> _values = new();

    public double GetDouble(string key, double defaultValue) =>
        _values.TryGetValue(key, out var v) && v is double d ? d : defaultValue;

    public void SetDouble(string key, double value) => _values[key] = value;

    public bool GetBool(string key, bool defaultValue) =>
        _values.TryGetValue(key, out var v) && v is bool b ? b : defaultValue;

    public void SetBool(string key, bool value) => _values[key] = value;
}

// MARK: - Fluent style (drop-in for direct glassEffect call sites)

/// <summary>
/// Mirror of the Swift <c>LiquidGlassStyle</c> fluent configuration, so call sites keep
/// the familiar spelling — <c>LiquidGlassStyle.Regular.Tint(accent).Interactive()</c> —
/// while routing through the transparency preference. On macOS this configures a
/// <c>Glass</c> value; here it resolves to a <see cref="LiquidGlassBackdropKind"/> plus a
/// tint, since Windows has no per-element glass material (R7).
/// </summary>
/// <remarks>Swift original: <c>struct LiquidGlassStyle</c> (macOS 26 only).</remarks>
public readonly struct LiquidGlassStyle
{
    public Color? TintColor { get; init; }
    public bool IsInteractive { get; init; }
    public bool ClearAtNeutral { get; init; }

    /// <summary>Swift: <c>static var regular</c>.</summary>
    public static LiquidGlassStyle Regular =>
        new() { TintColor = null, IsInteractive = false, ClearAtNeutral = false };

    /// <summary>Swift: <c>static var clear</c> — clear even at neutral <c>t</c>.</summary>
    public static LiquidGlassStyle Clear =>
        new() { TintColor = null, IsInteractive = false, ClearAtNeutral = true };

    /// <summary>Swift: <c>func tint(_:)</c>.</summary>
    public LiquidGlassStyle Tint(Color? color) => this with { TintColor = color };

    /// <summary>Swift: <c>func interactive(_:)</c>.</summary>
    public LiquidGlassStyle Interactive(bool isEnabled = true) => this with { IsInteractive = isEnabled };

    /// <summary>
    /// The backdrop kind this style resolves to at transparency <c>t</c>. Swift:
    /// <c>func resolvedGlass(at:)</c> — <c>shouldUseClear = clearAtNeutral ? t &gt;= 0 :
    /// usesClearGlass(t)</c>. When content surfaces are disabled the caller substitutes
    /// <see cref="LiquidGlassBackdropKind.Solid"/> (Swift: the fallback branch).
    /// </summary>
    public LiquidGlassBackdropKind ResolveBackdropKind(double t)
    {
        bool shouldUseClear = ClearAtNeutral ? t >= 0 : LiquidGlassTransparency.UsesClearGlass(t);
        if (shouldUseClear)
        {
            return LiquidGlassBackdropKind.Acrylic;
        }

        return t < 0 ? LiquidGlassBackdropKind.MicaBaseAlt : LiquidGlassBackdropKind.MicaBase;
    }
}

// MARK: - The chokepoint

/// <summary>
/// The Liquid-Glass chokepoint: attached properties for the surface vocabulary plus the
/// backdrop/brush resolution the whole app funnels through. The visual application is the
/// approximate-parity layer (R7); the resolution math is the exact-parity layer.
/// </summary>
public static class LiquidGlass
{
    /// <summary>
    /// Default for the content-surface toggle: true when the OS can render a glass
    /// backdrop (Windows 11 / DesktopAcrylic-capable), false otherwise (Windows 10 solid).
    /// The OS-capability analog of the Swift <c>defaultContentSurfacesEnabled</c>
    /// (<c>#available(macOS 26)</c>). Lives here (not in the pure-math
    /// <see cref="LiquidGlassTransparency"/>) because it touches WinUI backdrop controllers.
    /// </summary>
    public static bool DefaultContentSurfacesEnabled
    {
        get
        {
            try
            {
                return DesktopAcrylicController.IsSupported() || MicaController.IsSupported();
            }
            catch (Exception)
            {
                // The controllers throw on very old OSes / headless test hosts.
                return false;
            }
        }
    }

    // MARK: liquidGlassSurface -> LiquidGlass.Surface attached property

    /// <summary>Attached flag mirroring <c>View.liquidGlassSurface(in:)</c>: set
    /// <c>local:LiquidGlass.Surface="True"</c> on a <see cref="Border"/> (or any
    /// element with a <c>Background</c>/<c>Fill</c>) to paint the resolved glass surface
    /// brush from <see cref="LiquidGlassEnvironment.Current"/>.</summary>
    public static readonly DependencyProperty SurfaceProperty =
        DependencyProperty.RegisterAttached(
            "Surface",
            typeof(bool),
            typeof(LiquidGlass),
            new PropertyMetadata(false, OnSurfaceChanged));

    public static void SetSurface(DependencyObject element, bool value) =>
        element.SetValue(SurfaceProperty, value);

    public static bool GetSurface(DependencyObject element) =>
        (bool)element.GetValue(SurfaceProperty);

    private static void OnSurfaceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is Border border && e.NewValue is true)
        {
            border.Background = ResolveSurfaceBrush(LiquidGlassEnvironment.Current, tint: null);
        }
    }

    // MARK: liquidGlassInteractive -> LiquidGlass.Interactive attached property

    /// <summary>Attached flag mirroring <c>View.liquidGlassInteractive(in:)</c>. Pairs
    /// with <c>LiquidGlassInteractiveStyle</c> (Theme/LiquidGlass.xaml), whose
    /// PointerOver / Pressed VisualStates supply the pointer feedback that stands in for
    /// macOS interactive lensing (R7 — an opacity transition, not a light-bending lens).</summary>
    public static readonly DependencyProperty InteractiveProperty =
        DependencyProperty.RegisterAttached(
            "Interactive",
            typeof(bool),
            typeof(LiquidGlass),
            new PropertyMetadata(false));

    public static void SetInteractive(DependencyObject element, bool value) =>
        element.SetValue(InteractiveProperty, value);

    public static bool GetInteractive(DependencyObject element) =>
        (bool)element.GetValue(InteractiveProperty);

    // MARK: liquidGlassCircleButton -> LiquidGlass.CircleButtonDiameter attached property

    /// <summary>The recurring circular glass control (close ✕, collapse ⌄). Mirrors
    /// <c>View.liquidGlassCircleButton(diameter:)</c> — default diameter 30, matching the
    /// Swift default. Pairs with <c>LiquidGlassCircleButtonStyle</c>.</summary>
    public static readonly DependencyProperty CircleButtonDiameterProperty =
        DependencyProperty.RegisterAttached(
            "CircleButtonDiameter",
            typeof(double),
            typeof(LiquidGlass),
            new PropertyMetadata(30.0, OnCircleButtonDiameterChanged));

    public static void SetCircleButtonDiameter(DependencyObject element, double value) =>
        element.SetValue(CircleButtonDiameterProperty, value);

    public static double GetCircleButtonDiameter(DependencyObject element) =>
        (double)element.GetValue(CircleButtonDiameterProperty);

    private static void OnCircleButtonDiameterChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is FrameworkElement element && e.NewValue is double diameter && diameter > 0)
        {
            element.Width = diameter;
            element.Height = diameter;
            if (d is Control control)
            {
                control.CornerRadius = new CornerRadius(diameter / 2);
            }
        }
    }

    // MARK: - Resolution

    /// <summary>The backdrop kind for the given environment. Bundles the
    /// content-surfaces gate (Swift: the <c>#available … , contentSurfacesEnabled</c>
    /// guard) with the effective-transparency branch.</summary>
    public static LiquidGlassBackdropKind ResolveBackdropKind(LiquidGlassEnvironment env)
    {
        if (env is null)
        {
            throw new ArgumentNullException(nameof(env));
        }

        if (!env.ContentSurfacesEnabled)
        {
            return LiquidGlassBackdropKind.Solid;
        }

        double t = env.EffectiveTransparency;
        if (LiquidGlassTransparency.UsesClearGlass(t))
        {
            return LiquidGlassBackdropKind.Acrylic;
        }

        return t < 0 ? LiquidGlassBackdropKind.MicaBaseAlt : LiquidGlassBackdropKind.MicaBase;
    }

    /// <summary>
    /// Build the <see cref="SystemBackdrop"/> for a kind, or <c>null</c> for
    /// <see cref="LiquidGlassBackdropKind.Solid"/> (window keeps its solid theme brush —
    /// the honest Windows-10 / reduced-transparency fallback the master plan calls for).
    /// This is the window-level analog of choosing <c>Glass.regular</c> vs <c>Glass.clear</c>.
    /// </summary>
    public static SystemBackdrop? CreateSystemBackdrop(LiquidGlassBackdropKind kind) => kind switch
    {
        LiquidGlassBackdropKind.Acrylic => new DesktopAcrylicBackdrop(),
        LiquidGlassBackdropKind.MicaBaseAlt => new MicaBackdrop { Kind = MicaKind.BaseAlt },
        LiquidGlassBackdropKind.MicaBase => new MicaBackdrop { Kind = MicaKind.Base },
        _ => null,
    };

    /// <summary>
    /// Apply the resolved window backdrop to <paramref name="window"/>. Replaces the ad-hoc
    /// <c>WindowChrome.TryApplyMica</c> so the window honors the transparency preference and
    /// the Reduce-Transparency clamp. Returns the resolved kind so callers can layer a frost
    /// / clear-bridge scrim of the matching opacity (see <see cref="ResolveScrimOpacity"/>).
    /// </summary>
    public static LiquidGlassBackdropKind ApplyWindowBackdrop(Window window, LiquidGlassEnvironment env)
    {
        if (window is null)
        {
            throw new ArgumentNullException(nameof(window));
        }

        LiquidGlassBackdropKind kind = ResolveBackdropKind(env);
        window.SystemBackdrop = CreateSystemBackdrop(kind); // null -> solid theme brush.
        return kind;
    }

    /// <summary>
    /// The frost / clear-bridge scrim opacity a caller should layer between the backdrop and
    /// the content for the current environment. Swift: the <c>liquidGlassScrim(for:in:)</c>
    /// view builder — frost (<c>t &lt; 0</c>) takes precedence over the clear bridge
    /// (<c>t &gt; 0</c>); neutral is 0 (no scrim, default look untouched).
    /// </summary>
    public static double ResolveScrimOpacity(LiquidGlassEnvironment env)
    {
        if (env is null)
        {
            throw new ArgumentNullException(nameof(env));
        }

        double t = env.EffectiveTransparency;
        double frost = LiquidGlassTransparency.FrostScrimOpacity(t);
        return frost > 0 ? frost : LiquidGlassTransparency.ClearBridgeScrimOpacity(t);
    }

    /// <summary>
    /// The in-app surface brush for a card/tray/bar (the <c>liquidGlassSurface</c> plate).
    /// R7: Windows has no content-refracting per-element glass, so this is an
    /// <see cref="AcrylicBrush"/> (in-app acrylic, blurs the window backdrop) when clear, a
    /// translucent plate over Mica when neutral/frosty, and a solid brush when content
    /// surfaces are disabled — mirroring the three Swift branches
    /// (<c>.clear</c> glass / <c>.regular</c> glass / fallback material).
    /// </summary>
    public static Brush ResolveSurfaceBrush(LiquidGlassEnvironment env, Color? tint)
    {
        if (env is null)
        {
            throw new ArgumentNullException(nameof(env));
        }

        LiquidGlassBackdropKind kind = ResolveBackdropKind(env);
        double t = env.EffectiveTransparency;

        if (kind == LiquidGlassBackdropKind.Solid)
        {
            // Swift fallback branch: fallback material at fallbackPlateOpacity, tinted if asked.
            Color baseColor = tint ?? Color.FromArgb(0xFF, 0x1C, 0x1C, 0x1E);
            byte alpha = ToByte(LiquidGlassTransparency.FallbackPlateOpacity(t));
            return new SolidColorBrush(Color.FromArgb(alpha, baseColor.R, baseColor.G, baseColor.B));
        }

        if (kind == LiquidGlassBackdropKind.Acrylic)
        {
            // Clearer: in-app acrylic, tint opacity easing down as t -> 1 (more see-through).
            double tintOpacity = Math.Clamp(0.40 * (1 - 0.5 * t), 0.12, 0.60);
            var acrylic = new AcrylicBrush
            {
                TintColor = tint ?? Color.FromArgb(0xFF, 0x20, 0x20, 0x24),
                TintOpacity = tintOpacity,
                FallbackColor = Color.FromArgb(0xF2, 0x20, 0x20, 0x24),
            };
            return acrylic;
        }

        // Neutral / frosty: a translucent plate over Mica. Frost adds opacity as t -> -1.
        double plate = 0.14 + (t < 0 ? 0.70 * -t : 0);
        Color plateColor = tint ?? Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF);
        return new SolidColorBrush(Color.FromArgb(ToByte(plate), plateColor.R, plateColor.G, plateColor.B));
    }

    private static byte ToByte(double opacity) =>
        (byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255);
}

// MARK: - Behind-window blend (the "Clear" payoff)

/// <summary>
/// Blurred desktop showing through the window — the Windows payoff for the "Clear" side of
/// the transparency preference, and the analog of the macOS <c>LiquidGlassWindowBlend</c>
/// (an <c>NSVisualEffectView</c> with <c>.underWindowBackground</c> / <c>.behindWindow</c>).
/// On Windows that behind-window blend IS <see cref="DesktopAcrylicBackdrop"/>. Assign the
/// result to a window's <see cref="Window.SystemBackdrop"/> at the "Clear" end of the pref.
/// </summary>
/// <remarks>Swift original: <c>struct LiquidGlassWindowBlend : NSViewRepresentable</c>.</remarks>
public static class LiquidGlassWindowBlend
{
    /// <summary>The behind-window blurred-desktop backdrop.
    /// Swift: <c>LiquidGlassWindowBlend.makeVisualEffectView()</c>.</summary>
    public static SystemBackdrop MakeBackdrop() => new DesktopAcrylicBackdrop();
}

// MARK: - Grouping container

/// <summary>
/// No-op grouping container. The macOS <c>LiquidGlassGroup</c> wraps grouped glass in a
/// <c>GlassEffectContainer</c> so the elements share one sampling region (glass cannot
/// sample other glass). Windows has no glass-sampling-glass (R7), so there is nothing to
/// share and this simply hosts its content unchanged — the same "pass content through" the
/// Swift type does on macOS 14–15. Kept as a distinct type so call sites read identically
/// and a future compositor upgrade has a single seam to light up.
/// </summary>
/// <remarks>Swift original: <c>struct LiquidGlassGroup&lt;Content: View&gt;</c>.</remarks>
public sealed partial class LiquidGlassGroup : ContentControl
{
    /// <summary>Matches the Swift <c>spacing</c> init parameter. Purely advisory on Windows
    /// (no sampling region to size), retained for call-site parity.</summary>
    public double? Spacing { get; set; }

    public LiquidGlassGroup()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
    }
}
