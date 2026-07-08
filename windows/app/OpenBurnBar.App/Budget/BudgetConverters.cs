using System;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.Budget;
using Windows.UI;

namespace OpenBurnBar.App.Budget;

// Windows-only value converters + static x:Bind format helpers for the Budget surface. They
// touch Microsoft.UI.Xaml so they compile on Windows CI; on the macOS authoring host they are
// Roslyn syntax-checked and the app build reaches the XamlCompiler gate. The COLORING lives
// here (dark-shell resolutions of the macOS DesignSystem semantic colors) so the portable
// presentation layer stays color-free — the same split proven by SessionLogAccentBrushConverter.
// Glyphs are Segoe MDL2 Assets code points (approximate parity; final icon pass is a design task).

/// <summary>Maps a <see cref="BudgetChipSeverity"/> to its tint brush (50/80/100 bands).</summary>
public sealed partial class BudgetSeverityBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        BudgetChipSeverity severity = value is BudgetChipSeverity s ? s : BudgetChipSeverity.Normal;
        return new SolidColorBrush(BudgetPalette.Severity(severity));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a <see cref="BudgetChipSeverity"/> to a soft background wash (12% tint).</summary>
public sealed partial class BudgetSeverityWashConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        BudgetChipSeverity severity = value is BudgetChipSeverity s ? s : BudgetChipSeverity.Normal;
        Color c = BudgetPalette.Severity(severity);
        return new SolidColorBrush(Color.FromArgb(0x1F, c.R, c.G, c.B));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a <see cref="BudgetRuleScope"/> to its accent brush (Swift <c>scopeTint</c>).</summary>
public sealed partial class BudgetScopeBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        BudgetRuleScope scope = value is BudgetRuleScope s ? s : BudgetRuleScope.Global;
        return new SolidColorBrush(BudgetPalette.Scope(scope));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a <see cref="BudgetEventKind"/> to its tint brush (Swift event-row <c>tint</c>).</summary>
public sealed partial class BudgetEventBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        BudgetEventKind kind = value is BudgetEventKind k ? k : BudgetEventKind.Warning;
        return new SolidColorBrush(BudgetPalette.Event(kind));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Dark-shell resolutions of the macOS DesignSystem semantic colors the Budget UI uses.</summary>
public static class BudgetPalette
{
    // Semantic (DesignSystem.Colors.error / warning / textSecondary / success).
    public static readonly Color Error = Color.FromArgb(0xFF, 0xFF, 0x4D, 0x4F);
    public static readonly Color Warning = Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C);
    public static readonly Color Neutral = Color.FromArgb(0xFF, 0x8B, 0x94, 0xA8);
    public static readonly Color Success = Color.FromArgb(0xFF, 0x35, 0xC7, 0x59);
    public static readonly Color Coral = Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06);
    public static readonly Color Purple = Color.FromArgb(0xFF, 0xA8, 0x55, 0xF7);
    public static readonly Color Info = Color.FromArgb(0xFF, 0x4C, 0x8D, 0xFF);

    public static Color Severity(BudgetChipSeverity severity) => severity switch
    {
        BudgetChipSeverity.Blocked => Error,
        BudgetChipSeverity.Warning => Warning,
        _ => Neutral,
    };

    public static Color Scope(BudgetRuleScope scope) => scope switch
    {
        BudgetRuleScope.Global => Info,
        BudgetRuleScope.Credential => Color.FromArgb(0xFF, 0xE8, 0x61, 0x00),
        BudgetRuleScope.Project => Success,
        BudgetRuleScope.Organization => Purple,
        _ => Neutral,
    };

    public static Color Event(BudgetEventKind kind) => kind switch
    {
        BudgetEventKind.Warning => Warning,
        BudgetEventKind.Block => Error,
        BudgetEventKind.Override => Purple,
        BudgetEventKind.Pause => Neutral,
        BudgetEventKind.Resume => Info,
        _ => Neutral,
    };
}

/// <summary>
/// Static formatting helpers callable from x:Bind (the Windows peer of the Swift views'
/// scopeIcon / periodLabel / behaviorLabel / event-row computed properties). Pure so the row
/// templates read straight from a <see cref="BudgetRule"/> / <see cref="BudgetEvent"/>.
/// </summary>
public static class BudgetFormat
{
    public static string Amount(double amount) =>
        string.Format(System.Globalization.CultureInfo.InvariantCulture, "${0:F2}", amount);

    public static string PeriodLabel(BudgetPeriod period) => period switch
    {
        BudgetPeriod.Day => "per day",
        BudgetPeriod.Week => "per week",
        BudgetPeriod.Month => "per month",
        BudgetPeriod.AllTime => "all time",
        _ => "per month",
    };

    public static string ScopeGlyph(BudgetRuleScope scope) => scope switch
    {
        BudgetRuleScope.Global => "",        // Globe
        BudgetRuleScope.Credential => "",    // Permissions (key)
        BudgetRuleScope.Project => "",       // Folder
        BudgetRuleScope.Organization => "",  // People
        _ => "",
    };

    public static string SeverityGlyph(BudgetChipSeverity severity) => severity switch
    {
        BudgetChipSeverity.Blocked => "",    // Cancel (octagon analog)
        BudgetChipSeverity.Warning => "",    // Warning
        _ => "",                             // Speed (gauge)
    };

    public static string BehaviorLabel(BudgetBehavior behavior) => behavior switch
    {
        BudgetBehavior.WarnThenBlock => "warn then block",
        BudgetBehavior.HardBlock => "hard block",
        BudgetBehavior.WarnOnly => "warn only",
        BudgetBehavior.HardBlockWithFallback => "block + failover",
        _ => "warn then block",
    };

    /// <summary>
    /// Row subtitle: behavior [· paused] [· disabled]. Mirrors the Swift <c>subtitle</c>. Takes
    /// scalar fields (not the whole rule) so x:Bind can call it directly from a row template.
    /// </summary>
    public static string RuleSubtitle(BudgetBehavior behavior, DateTimeOffset? pausedUntil, bool isEnabled)
    {
        string subtitle = BehaviorLabel(behavior);
        if (pausedUntil is DateTimeOffset until && until > DateTimeOffset.UtcNow)
        {
            subtitle += " · paused";
        }

        if (!isEnabled)
        {
            subtitle += " · disabled";
        }

        return subtitle;
    }

    public static string EventTitle(BudgetEventKind kind) => kind switch
    {
        BudgetEventKind.Warning => "Warning fired",
        BudgetEventKind.Block => "Request blocked",
        BudgetEventKind.Override => "Override used",
        BudgetEventKind.Pause => "Gate paused",
        BudgetEventKind.Resume => "Gate resumed",
        BudgetEventKind.RuleCreated => "Rule created",
        BudgetEventKind.RuleUpdated => "Rule updated",
        BudgetEventKind.RuleDeleted => "Rule deleted",
        _ => "Budget event",
    };

    public static string EventGlyph(BudgetEventKind kind) => kind switch
    {
        BudgetEventKind.Warning => "",       // Warning
        BudgetEventKind.Block => "",         // Cancel
        BudgetEventKind.Override => "",      // Redo
        BudgetEventKind.Pause => "",         // Pause
        BudgetEventKind.Resume => "",        // Play
        _ => "",                             // Page (document)
    };

    public static string EventTimestamp(DateTimeOffset occurredAt) =>
        occurredAt.ToLocalTime().ToString("MMM d, h:mm tt", System.Globalization.CultureInfo.InvariantCulture);

    public static string EventAmounts(double amountAtEvent, double limitAtEvent)
    {
        if (limitAtEvent <= 0)
        {
            return string.Empty;
        }

        return string.Format(
            System.Globalization.CultureInfo.InvariantCulture,
            "${0:F2} / ${1:F2}",
            amountAtEvent, limitAtEvent);
    }
}
