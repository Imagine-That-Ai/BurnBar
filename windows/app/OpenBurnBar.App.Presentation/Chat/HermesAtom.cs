using System;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Hermes Atom
//
// C# peer of `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtom.swift`.
//
// Typed set of "conversation atoms" — entities Hermes references in chat which
// the OpenBurnBar app already has dedicated UI for. Atoms are emitted by Hermes
// (or detected from prose) and rendered as atomic inline chips that, when
// tapped, navigate to the matching native surface.
//
// Swift models this as an `enum HermesAtom` with associated values. C# has no
// enum-with-payload, so each case becomes a small `sealed record` under the
// abstract `HermesAtom` base — records give the same value-equality +
// hashability the Swift `Hashable` conformance relied on, and `switch`
// expressions over the record types recover exhaustive pattern matching.

/// Time window selector reused across the app's analytics surfaces
/// (peer of Swift `HermesAtomWindow`). Raw values match the Swift `rawValue`
/// so `burnbar://` URLs round-trip byte-for-byte.
public enum HermesAtomWindow
{
    Today,
    Yesterday,
    SevenDays,
    ThirtyDays,
    NinetyDays,
    All,
}

/// Categorical group of token-volume scopes (peer of Swift `HermesAtomTokenScope`).
public enum HermesAtomTokenScope
{
    Today,
    Session,
    Run,
    Lifetime,
    Unspecified,
}

/// Visual / behavioral category for an atom (peer of Swift `HermesAtomKind`).
/// Drives icon / accent / label choices; the concrete glyph + color resolution
/// lives in the WinUI layer (a different design system than macOS SF Symbols).
public enum HermesAtomKind
{
    Cost,
    Session,
    Provider,
    Model,
    Window,
    Tool,
    Project,
    Tokens,
    Quota,
    Runtime,
}

/// Raw-value helpers so the URL codec and window/scope labels match Swift's
/// `String` raw values exactly.
public static class HermesAtomWindowRaw
{
    public static string ToRawValue(this HermesAtomWindow window) => window switch
    {
        HermesAtomWindow.Today => "today",
        HermesAtomWindow.Yesterday => "yesterday",
        HermesAtomWindow.SevenDays => "7d",
        HermesAtomWindow.ThirtyDays => "30d",
        HermesAtomWindow.NinetyDays => "90d",
        HermesAtomWindow.All => "all",
        _ => "today",
    };

    public static HermesAtomWindow? FromRawValue(string? raw) => raw switch
    {
        "today" => HermesAtomWindow.Today,
        "yesterday" => HermesAtomWindow.Yesterday,
        "7d" => HermesAtomWindow.SevenDays,
        "30d" => HermesAtomWindow.ThirtyDays,
        "90d" => HermesAtomWindow.NinetyDays,
        "all" => HermesAtomWindow.All,
        _ => null,
    };

    public static string DisplayLabel(this HermesAtomWindow window) => window switch
    {
        HermesAtomWindow.Today => "today",
        HermesAtomWindow.Yesterday => "yesterday",
        HermesAtomWindow.SevenDays => "7 days",
        HermesAtomWindow.ThirtyDays => "30 days",
        HermesAtomWindow.NinetyDays => "90 days",
        HermesAtomWindow.All => "all time",
        _ => "today",
    };
}

public static class HermesAtomTokenScopeRaw
{
    public static string ToRawValue(this HermesAtomTokenScope scope) => scope switch
    {
        HermesAtomTokenScope.Today => "today",
        HermesAtomTokenScope.Session => "session",
        HermesAtomTokenScope.Run => "run",
        HermesAtomTokenScope.Lifetime => "lifetime",
        HermesAtomTokenScope.Unspecified => "unspecified",
        _ => "unspecified",
    };

    public static HermesAtomTokenScope? FromRawValue(string? raw) => raw switch
    {
        "today" => HermesAtomTokenScope.Today,
        "session" => HermesAtomTokenScope.Session,
        "run" => HermesAtomTokenScope.Run,
        "lifetime" => HermesAtomTokenScope.Lifetime,
        "unspecified" => HermesAtomTokenScope.Unspecified,
        _ => null,
    };

    public static string DisplayLabel(this HermesAtomTokenScope scope) => scope switch
    {
        HermesAtomTokenScope.Today => "today",
        HermesAtomTokenScope.Session => "this session",
        HermesAtomTokenScope.Run => "this run",
        HermesAtomTokenScope.Lifetime => "lifetime",
        HermesAtomTokenScope.Unspecified => "",
        _ => "",
    };
}

/// One conversation atom — a strongly-typed reference to an app entity, carrying
/// enough data to navigate plus a <see cref="Kind"/> that drives icon/accent/label.
public abstract record HermesAtom
{
    private HermesAtom()
    {
    }

    public abstract HermesAtomKind Kind { get; }

    /// A monetary cost across some time window (display-only; Decimal-as-double
    /// mirrors the Swift note about avoiding Decimal Codable bridging).
    public sealed record Cost(double Amount, HermesAtomWindow Window) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Cost;
    }

    public sealed record Session(string Id) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Session;
    }

    // Named `ProviderRef` (not `Provider`) so it does not collide with the
    // positional parameter `Provider` on the `Quota` record below (C# resolves
    // the nested type over the synthesized property otherwise → CS8866).
    public sealed record ProviderRef(string Token) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Provider;
    }

    public sealed record Model(string Id) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Model;
    }

    // Named `WindowRef` (not `Window`) so it does not collide with the positional
    // parameter `Window` on the `Cost` record above (same CS8866 reason).
    public sealed record WindowRef(HermesAtomWindow Value) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Window;
    }

    public sealed record Tool(string Name) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Tool;
    }

    public sealed record Project(string Id) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Project;
    }

    public sealed record Tokens(int Value, HermesAtomTokenScope Scope) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Tokens;
    }

    public sealed record Quota(string Provider, int Percent) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Quota;
    }

    public sealed record Runtime(string Profile) : HermesAtom
    {
        public override HermesAtomKind Kind => HermesAtomKind.Runtime;
    }

    /// Default label used when the source label is missing or whitespace-only.
    /// Byte-for-byte port of Swift `HermesAtom.fallbackLabel`.
    public string FallbackLabel => this switch
    {
        Cost c => $"{FormatCurrency(c.Amount)} {c.Window.DisplayLabel()}",
        Session s => $"session {Prefix(s.Id, 8)}",
        ProviderRef p => Capitalized(p.Token),
        Model m => m.Id,
        WindowRef w => w.Value.DisplayLabel(),
        Tool t => t.Name,
        Project pr => pr.Id,
        Tokens tk => tk.Scope == HermesAtomTokenScope.Unspecified
            ? $"{FormatTokenCount(tk.Value)} tokens"
            : $"{FormatTokenCount(tk.Value)} {tk.Scope.DisplayLabel()}",
        Quota q => $"{q.Percent}% {Capitalized(q.Provider)}",
        Runtime r => Capitalized(r.Profile),
        _ => "",
    };

    /// Human-friendly token count formatter — `12.4k`, `1.2M`, `3.40B`.
    /// Byte-for-byte port of Swift `HermesAtom.formatTokenCount`.
    public static string FormatTokenCount(int value)
    {
        if (value < 1_000)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
        if (value < 1_000_000)
        {
            var k = value / 1_000.0;
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0}k", k);
        }
        if (value >= 1_000_000_000)
        {
            var b = value / 1_000_000_000.0;
            return string.Format(CultureInfo.InvariantCulture, "{0:0.00}B", b);
        }
        var m = value / 1_000_000.0;
        return string.Format(CultureInfo.InvariantCulture, "{0:0.0}M", m);
    }

    // Mirror of Swift's `NumberFormatter(.currency, USD, maxFractionDigits: 2)`
    // for the common en-US formatting the chip renders.
    private static string FormatCurrency(double amount) =>
        amount.ToString("C2", CultureInfo.GetCultureInfo("en-US"));

    private static string Capitalized(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }
        return char.ToUpper(value[0], CultureInfo.InvariantCulture) + value.Substring(1);
    }

    private static string Prefix(string value, int count) =>
        value.Length <= count ? value : value.Substring(0, count);
}

/// Presentation metadata for a <see cref="HermesAtomKind"/> — category label +
/// one-line description. The WinUI layer maps <see cref="HermesAtomKind"/> to a
/// Segoe glyph + accent brush (peer of the Swift `systemImage`/`categoryLabel`/
/// `description` computed properties, minus the Apple-only SF Symbol names).
public static class HermesAtomKindMetadata
{
    public static string CategoryLabel(this HermesAtomKind kind) => kind switch
    {
        HermesAtomKind.Cost => "Cost",
        HermesAtomKind.Session => "Session",
        HermesAtomKind.Provider => "Provider",
        HermesAtomKind.Model => "Model",
        HermesAtomKind.Window => "Window",
        HermesAtomKind.Tool => "Tool",
        HermesAtomKind.Project => "Project",
        HermesAtomKind.Tokens => "Tokens",
        HermesAtomKind.Quota => "Quota",
        HermesAtomKind.Runtime => "Runtime",
        _ => "",
    };

    public static string Description(this HermesAtomKind kind) => kind switch
    {
        HermesAtomKind.Cost => "Open the burn detail for this time window.",
        HermesAtomKind.Session => "Open this session's detail view.",
        HermesAtomKind.Provider => "Open this provider's dashboard.",
        HermesAtomKind.Model => "Open this model's detail or pick it as default.",
        HermesAtomKind.Window => "Switch the dashboard to this time window.",
        HermesAtomKind.Tool => "See where this tool was invoked in the run.",
        HermesAtomKind.Project => "Open this project's detail.",
        HermesAtomKind.Tokens => "Open the token-usage detail.",
        HermesAtomKind.Quota => "Open quota detail for this provider.",
        HermesAtomKind.Runtime => "Open Hermes runtime details for this profile.",
        _ => "",
    };
}
