using System;

namespace OpenBurnBar.Storage;

/// <summary>GRDB/SQLite datetime storage as ISO-8601 text (matches Mac <c>OpenBurnBarDatabase</c> codecs).</summary>
internal static class StorageDateCodec
{
    public static string ToIso(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", System.Globalization.CultureInfo.InvariantCulture);

    public static DateTimeOffset FromIso(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return DateTimeOffset.UtcNow;
        }

        if (DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed))
        {
            return parsed;
        }

        return DateTimeOffset.UtcNow;
    }

    public static double ToUnixSeconds(DateTimeOffset value) => value.ToUnixTimeSeconds();
}