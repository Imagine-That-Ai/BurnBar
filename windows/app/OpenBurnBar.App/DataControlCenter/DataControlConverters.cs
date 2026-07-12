using System;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Windows.UI;

namespace OpenBurnBar.App.DataControlCenter;

// Windows-only value converters + tier/glyph display helpers the Data Control Center XAML binds to.
// They touch Microsoft.UI.Xaml, so they compile on Windows CI; on the macOS authoring host they are
// Roslyn syntax-checked and the app build reaches the XamlCompiler gate (the documented ceiling).
//
// The tier PALETTE mirrors AgentLens/Views/Settings/DataControlCenter/DataControlCenterTheme.swift
// (PensieveTheme.tint) — the same three token colors (server-readable amber, zero-access steel,
// end-to-end teal) that live in Theme/Tokens.xaml (PensieveColorTier*). Colors are built inline
// (matching Converters/CommonConverters.cs) so a converter never does a resource lookup. Glyphs are
// Segoe MDL2 Assets code points written as \uXXXX escapes (final icon parity is a design pass).

/// <summary>Maps an <see cref="EncryptionTier"/> to its accent brush. Swift: <c>PensieveTheme.tint</c>.</summary>
public sealed partial class TierBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        new SolidColorBrush(TierDisplay.AccentColor(value as EncryptionTier? ?? EncryptionTier.ServerReadable));

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps an <see cref="EncryptionTier"/> to a soft (14%) fill for badges/pills.</summary>
public sealed partial class TierSoftBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        Color c = TierDisplay.AccentColor(value as EncryptionTier? ?? EncryptionTier.ServerReadable);
        return new SolidColorBrush(Color.FromArgb(0x24, c.R, c.G, c.B));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps an <see cref="EncryptionTier"/> to its Segoe MDL2 glyph. Swift: <c>tier.iconName</c>.</summary>
public sealed partial class TierGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        TierDisplay.Glyph(value as EncryptionTier? ?? EncryptionTier.ServerReadable);

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps an <see cref="EncryptionTier"/> to its display label. Swift: <c>tier.displayLabel</c>.</summary>
public sealed partial class TierLabelConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        TierDisplay.Label(value as EncryptionTier? ?? EncryptionTier.ServerReadable);

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Formats a byte count as a human-readable size ("—" for zero). Swift: <c>ByteCountFormatter</c>.</summary>
public sealed partial class BytesToStringConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        long bytes = value switch
        {
            long l => l,
            int i => i,
            _ => 0,
        };

        return bytes > 0 ? DataControlFormat.Bytes(bytes) : "—";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Formats a retention token as friendly copy. Swift: <c>DomainInspector.retentionLabel</c>.</summary>
public sealed partial class RetentionLabelConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        TierDisplay.RetentionLabel(value as string ?? string.Empty);

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a domain to its Segoe MDL2 sidebar/inventory glyph.</summary>
public sealed partial class DomainGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        DomainGlyphMap.Glyph((value as DataDomain)?.Id ?? (value as string));

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Non-negative-count → Visibility (visible when the domain holds records).</summary>
public sealed partial class HasRecordsToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        int count = value switch { int i => i, long l => (int)l, _ => 0 };
        return count >= 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>The tier palette + display strings, mirroring the macOS PensieveTheme tier helpers.</summary>
public static class TierDisplay
{
    // Token colors (Theme/Tokens.xaml PensieveColorTier*): amber / steel / teal.
    public static Color AccentColor(EncryptionTier tier) => tier switch
    {
        EncryptionTier.ServerReadable => Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C),
        EncryptionTier.ZeroAccess => Color.FromArgb(0xFF, 0x8B, 0x94, 0xA8),
        EncryptionTier.EndToEnd => Color.FromArgb(0xFF, 0x3C, 0xD6, 0xC0),
        _ => Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C),
    };

    public static string Label(EncryptionTier tier) => tier switch
    {
        EncryptionTier.ServerReadable => "Server-readable",
        EncryptionTier.ZeroAccess => "Zero-access",
        EncryptionTier.EndToEnd => "End-to-end",
        _ => "Server-readable",
    };

    // Segoe MDL2: RedEye (server can see) / Lock (encrypted at rest) / Shield (sealed).
    public static string Glyph(EncryptionTier tier) => tier switch
    {
        EncryptionTier.ServerReadable => "", // RedEye
        EncryptionTier.ZeroAccess => "",     // Lock
        EncryptionTier.EndToEnd => "",       // Shield
        _ => "",
    };

    public static string Explanation(EncryptionTier tier) => tier switch
    {
        EncryptionTier.ServerReadable => "Stored as plaintext. BurnBar's servers can read this to run the product.",
        EncryptionTier.ZeroAccess => "Encrypted at rest. BurnBar holds only the wrapped key under your device trust — it cannot read the content.",
        EncryptionTier.EndToEnd => "Sealed on your device with the vault key. BurnBar never sees the plaintext or the key.",
        _ => string.Empty,
    };

    public static string RetentionLabel(string retention) => retention switch
    {
        "rolling" => "Rolling window",
        "until_deleted" => "Kept until you delete it",
        "until_revoked" => "Kept until revoked",
        "until_disconnected" => "Kept until disconnected",
        "append_only" => "Append-only",
        "permanent" => "Permanent record",
        _ => Capitalize(retention.Replace('_', ' ')),
    };

    private static string Capitalize(string value) =>
        string.IsNullOrEmpty(value) ? value : char.ToUpper(value[0], CultureInfo.InvariantCulture) + value.Substring(1);
}

/// <summary>Byte-size formatting shared by the inventory + inspector.</summary>
public static class DataControlFormat
{
    private static readonly string[] Units = { "bytes", "KB", "MB", "GB", "TB", "PB" };

    /// <summary>File-style human size (1000-based, matching macOS <c>ByteCountFormatter.file</c>).</summary>
    public static string Bytes(long bytes)
    {
        if (bytes < 1000)
        {
            return $"{bytes} bytes";
        }

        double value = bytes;
        int unit = 0;
        while (value >= 1000 && unit < Units.Length - 1)
        {
            value /= 1000;
            unit++;
        }

        return string.Format(CultureInfo.CurrentCulture, "{0:0.#} {1}", value, Units[unit]);
    }
}

/// <summary>
/// Domain id → Segoe MDL2 glyph. The macOS registry stores SF Symbol names; this is the Windows
/// render mapping (final icon parity is a design pass, per the NavCatalog note).
/// </summary>
public static class DomainGlyphMap
{
    public static string Glyph(string? domainId) => domainId switch
    {
        "usage_spend" => "",          // Chart
        "conversations_chat" => "",   // Message
        "session_logs" => "",         // History
        "pensieve" => "",             // Library
        "provider_accounts" => "",    // Permissions
        "connected_devices" => "",    // CellPhone
        "external_mcp" => "",         // Unlock / key
        "computer_use" => "",         // DeveloperTools
        "media" => "",                // Photo
        "entitlements_billing" => "", // PaymentCard
        "device_trust_keys" => "",    // SecureApp / shield
        "audit_timeline" => "",       // BulletedList
        _ => "",                      // Folder (fallback)
    };
}
