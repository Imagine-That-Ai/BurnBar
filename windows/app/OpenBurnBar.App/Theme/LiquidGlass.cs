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
    private static LiquidGlassEnvironment _current =
        new LiquidGlassEnvironment(new InMemoryPreferenceStore());

    /// <summary>
    /// Raised when any glass preference mutates (transparency, content surfaces, or a
    /// custom key via <see cref="NotifyChanged"/>). ThemeService and glass surfaces
    /// re-apply backdrop + plate brushes on this event.
    /// </summary>
    public static event EventHandler? PreferencesChanged;

    /// <summary>The process-wide environment used by the attached properties and window
    /// backdrop helper. Settings surfaces mutate this; changes re-apply via
    /// <see cref="PreferencesChanged"/>.</summary>
    public static LiquidGlassEnvironment Current
    {
        get => _current;
        set
        {
            _current = value ?? throw new ArgumentNullException(nameof(value));
            RaisePreferencesChanged();
        }
    }

    public LiquidGlassEnvironment(ILiquidGlassPreferenceStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
    }

    /// <summary>The backing store (registry / in-memory / test double).</summary>
    public ILiquidGlassPreferenceStore Store => _store;

    /// <summary>Raw, unclamped stored preference. Swift: <c>@AppStorage(storageKey) rawTransparency</c>.</summary>
    public double RawTransparency
    {
        get => _store.GetDouble(LiquidGlassTransparency.StorageKey, 0);
        set
        {
            double clamped = double.IsNaN(value) || double.IsInfinity(value)
                ? 0
                : Math.Min(Math.Max(value, LiquidGlassTransparency.RangeLowerBound), LiquidGlassTransparency.RangeUpperBound);
            if (Math.Abs(RawTransparency - clamped) < 1e-12)
            {
                return;
            }

            _store.SetDouble(LiquidGlassTransparency.StorageKey, clamped);
            RaisePreferencesChanged();
        }
    }

    /// <summary>Whether content-level surfaces use glass. Swift:
    /// <c>@AppStorage(contentSurfacesEnabledKey) contentSurfacesEnabled</c> with the same default.</summary>
    public bool ContentSurfacesEnabled
    {
        get => _store.GetBool(
            LiquidGlassTransparency.ContentSurfacesEnabledKey,
            LiquidGlass.DefaultContentSurfacesEnabled);
        set
        {
            if (ContentSurfacesEnabled == value)
            {
                return;
            }

            _store.SetBool(LiquidGlassTransparency.ContentSurfacesEnabledKey, value);
            RaisePreferencesChanged();
        }
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

    /// <summary>Read a string preference (e.g. kernel backdrop id).</summary>
    public string GetString(string key, string defaultValue) => _store.GetString(key, defaultValue);

    /// <summary>Write a string preference and raise <see cref="PreferencesChanged"/>.</summary>
    public void SetString(string key, string value)
    {
        string next = value ?? string.Empty;
        if (string.Equals(_store.GetString(key, string.Empty), next, StringComparison.Ordinal))
        {
            return;
        }

        _store.SetString(key, next);
        RaisePreferencesChanged();
    }

    /// <summary>Read a bool preference (e.g. kernel backdrop enabled).</summary>
    public bool GetBool(string key, bool defaultValue) => _store.GetBool(key, defaultValue);

    /// <summary>Write a bool preference and raise <see cref="PreferencesChanged"/>.</summary>
    public void SetBool(string key, bool value)
    {
        // Skip no-op writes when the key is already explicitly stored as value.
        // Probe with both defaults: if both return the same value, the key is present.
        // First write from an implicit default still persists (defaults disagree).
        if (_store.GetBool(key, value) == value && _store.GetBool(key, !value) == value)
        {
            return;
        }

        _store.SetBool(key, value);
        RaisePreferencesChanged();
    }

    /// <summary>Force a re-apply (e.g. after OS transparency setting changes).</summary>
    public static void NotifyChanged() => RaisePreferencesChanged();

    private static void RaisePreferencesChanged()
    {
        LiquidGlass.InvalidateRegisteredSurfaces();
        PreferencesChanged?.Invoke(null, EventArgs.Empty);
    }
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
    private static readonly System.Collections.Generic.List<WeakReference<Border>> SurfaceTargets = new();

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
        if (d is not Border border)
        {
            return;
        }

        if (e.NewValue is true)
        {
            RegisterSurface(border);
            ApplySurfaceBrush(border);
        }
    }

    private static void RegisterSurface(Border border)
    {
        for (int i = SurfaceTargets.Count - 1; i >= 0; i--)
        {
            if (!SurfaceTargets[i].TryGetTarget(out Border? existing) || ReferenceEquals(existing, border))
            {
                if (existing is null)
                {
                    SurfaceTargets.RemoveAt(i);
                }
                else
                {
                    return; // already tracked
                }
            }
        }

        SurfaceTargets.Add(new WeakReference<Border>(border));
    }

    private static void ApplySurfaceBrush(Border border) =>
        border.Background = ResolveSurfaceBrush(LiquidGlassEnvironment.Current, tint: null);

    /// <summary>
    /// Re-resolve every registered glass plate after a transparency preference change.
    /// Dead weak refs are pruned.
    /// </summary>
    public static void InvalidateRegisteredSurfaces()
    {
        for (int i = SurfaceTargets.Count - 1; i >= 0; i--)
        {
            if (SurfaceTargets[i].TryGetTarget(out Border? border) && border is not null)
            {
                ApplySurfaceBrush(border);
            }
            else
            {
                SurfaceTargets.RemoveAt(i);
            }
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
            // Plate color = macOS Aurora surface (#161B22) — the slate plate both the Mac
            // (DesignSystem.Colors.surface dark) and Linux (--glass-tint-base lineage) render.
            Color baseColor = tint ?? Color.FromArgb(0xFF, 0x16, 0x1B, 0x22);
            byte alpha = ToByte(LiquidGlassTransparency.FallbackPlateOpacity(t));
            return new SolidColorBrush(Color.FromArgb(alpha, baseColor.R, baseColor.G, baseColor.B));
        }

        if (kind == LiquidGlassBackdropKind.Acrylic)
        {
            // Clearer: in-app acrylic, tint opacity easing down as t -> 1 (more see-through).
            double tintOpacity = Math.Clamp(0.40 * (1 - 0.5 * t), 0.12, 0.60);
            var acrylic = new AcrylicBrush
            {
                TintColor = tint ?? Color.FromArgb(0xFF, 0x16, 0x1B, 0x22),
                TintOpacity = tintOpacity,
                FallbackColor = Color.FromArgb(0xF2, 0x16, 0x1B, 0x22),
            };
            return acrylic;
        }

        // Neutral / frosty: a translucent plate over Mica. Frost adds opacity as t -> -1.
        // Plate = Aurora surfaceElevated (#1F2630): dark slate glass, matching the macOS
        // ultraThin/thickMaterial fallbacks and the Linux --glass-tint-* recipes. (White
        // plates rendered as light-gray blobs with inverted text on the dark canvas —
        // the "amateur hour" look in the first physical screenshots.)
        double plate = 0.14 + (t < 0 ? 0.70 * -t : 0);
        Color plateColor = tint ?? Color.FromArgb(0xFF, 0x1F, 0x26, 0x30);
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
/// The in-tree <see cref="Border"/> host is a frost/clear scrim layer so XAML can place
/// content over the system backdrop without an opaque ink root.
/// </summary>
/// <remarks>Swift original: <c>struct LiquidGlassWindowBlend : NSViewRepresentable</c>.</remarks>
public static class LiquidGlassWindowBlend
{
    /// <summary>The behind-window blurred-desktop backdrop.
    /// Swift: <c>LiquidGlassWindowBlend.makeVisualEffectView()</c>.</summary>
    public static SystemBackdrop MakeBackdrop() => new DesktopAcrylicBackdrop();

    /// <summary>
    /// Build a full-bleed, hit-test-disabled scrim Border whose opacity tracks
    /// <see cref="LiquidGlass.ResolveScrimOpacity"/>. Layer this behind content so Clear
    /// lets the Mica/Acrylic desktop show through and Frost adds a thick plate.
    /// </summary>
    public static Border CreateScrimLayer(LiquidGlassEnvironment? env = null)
    {
        env ??= LiquidGlassEnvironment.Current;
        double opacity = LiquidGlass.ResolveScrimOpacity(env);
        // Scrim color = macOS Aurora canvas (#0D1117) — matches the Linux --macos-bg window field.
        return new Border
        {
            IsHitTestVisible = false,
            Background = new SolidColorBrush(Color.FromArgb(
                (byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255),
                0x0D, 0x11, 0x17)),
            Opacity = opacity <= 0 ? 0 : 1,
        };
    }

    /// <summary>Update an existing scrim layer after a preference change.</summary>
    public static void ApplyScrim(Border scrim, LiquidGlassEnvironment? env = null)
    {
        if (scrim is null)
        {
            throw new ArgumentNullException(nameof(scrim));
        }

        env ??= LiquidGlassEnvironment.Current;
        double opacity = LiquidGlass.ResolveScrimOpacity(env);
        byte alpha = (byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255);
        scrim.Background = new SolidColorBrush(Color.FromArgb(alpha, 0x0D, 0x11, 0x17));
        scrim.Opacity = opacity <= 0 ? 0 : 1;
    }
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
