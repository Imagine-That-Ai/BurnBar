using System;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Quota.Acquisition;

// ── MECHANISM 2 · state.vscdb read ───────────────────────────────────────────
//
// Windows peer of OpenBurnBarCore/.../ProviderQuota/CursorCookieExtractor.swift:
// a read-only, in-place SQLite read of Cursor's own `state.vscdb` (an editor
// `ItemTable` key/value store) extracting the auth JWT + cached email +
// membership, and deriving the `WorkosCursorSessionToken={userId}::{jwt}` cookie
// (userId = the JWT `sub` claim, portion after `|`). The Mac opens the live file
// with SQLITE_OPEN_READONLY and no copy; mirrored here via Mode=ReadOnly,
// Pooling=false (the storage/ open pattern).

/// <summary>The credentials extracted from Cursor's state.vscdb.</summary>
public sealed record CursorStateCredentials(
    string AccessToken,
    string UserId,
    string? CachedEmail,
    string? MembershipType)
{
    /// <summary>Swift <c>CursorSession.cookieHeader</c>.</summary>
    public string CookieHeader => $"WorkosCursorSessionToken={UserId}::{AccessToken}";
}

/// <summary>Read-only extractor over Cursor's <c>state.vscdb</c>.</summary>
public static class CursorStateDbReader
{
    /// <summary>Swift <c>CursorCookieExtractor</c> ItemTable keys.</summary>
    public const string AccessTokenKey = "cursorAuth/accessToken";

    /// <summary>Cached account email key.</summary>
    public const string CachedEmailKey = "cursorAuth/cachedEmail";

    /// <summary>Stripe membership key.</summary>
    public const string MembershipTypeKey = "cursorAuth/stripeMembershipType";

    /// <summary>
    /// Read the credentials. Returns <c>null</c> when the DB is missing, locked,
    /// the token row is absent, or the JWT carries no <c>sub</c> — all "no signal".
    /// </summary>
    public static CursorStateCredentials? TryRead(string stateDbPath)
    {
        if (string.IsNullOrWhiteSpace(stateDbPath) || !System.IO.File.Exists(stateDbPath))
        {
            return null;
        }

        try
        {
            SqlCipherParameters.EnsureProviderInitialized();
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = stateDbPath,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
            }.ToString();

            using var connection = new SqliteConnection(connectionString);
            connection.Open();

            var token = Normalize(ReadItem(connection, AccessTokenKey));
            if (token is null)
            {
                return null;
            }

            var userId = TryExtractJwtUserId(token);
            if (userId is null)
            {
                return null;
            }

            return new CursorStateCredentials(
                token,
                userId,
                Normalize(ReadItem(connection, CachedEmailKey)),
                Normalize(ReadItem(connection, MembershipTypeKey)));
        }
        catch (SqliteException)
        {
            return null;
        }
    }

    private static string? ReadItem(SqliteConnection connection, string key)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM ItemTable WHERE key = $key LIMIT 1;";
        command.Parameters.AddWithValue("$key", key);
        var value = command.ExecuteScalar();
        return value switch
        {
            string text => text,
            byte[] blob => Encoding.UTF8.GetString(blob),
            _ => null,
        };
    }

    /// <summary>
    /// Trim, and strip one layer of surrounding double quotes (some ItemTable
    /// values are JSON-encoded strings). Empty → <c>null</c>.
    /// </summary>
    private static string? Normalize(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var trimmed = value.Trim();
        if (trimmed.Length >= 2 && trimmed[0] == '"' && trimmed[^1] == '"')
        {
            trimmed = trimmed[1..^1].Trim();
        }

        return trimmed.Length == 0 ? null : trimmed;
    }

    /// <summary>
    /// Swift <c>extractUserIdFromJWT</c>: base64url-decode the JWT payload, read
    /// the <c>sub</c> claim, and keep the portion after <c>|</c> when present.
    /// </summary>
    public static string? TryExtractJwtUserId(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length < 2)
        {
            return null;
        }

        byte[] payload;
        try
        {
            payload = Base64UrlDecode(parts[1]);
        }
        catch (FormatException)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("sub", out var sub)
                || sub.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            var value = sub.GetString();
            if (string.IsNullOrWhiteSpace(value))
            {
                return null;
            }

            var separator = value.IndexOf('|', StringComparison.Ordinal);
            var userId = separator >= 0 ? value[(separator + 1)..] : value;
            return userId.Length == 0 ? null : userId;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static byte[] Base64UrlDecode(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        var padding = normalized.Length % 4;
        if (padding == 2)
        {
            normalized += "==";
        }
        else if (padding == 3)
        {
            normalized += "=";
        }
        else if (padding == 1)
        {
            throw new FormatException("Invalid base64url length.");
        }

        return Convert.FromBase64String(normalized);
    }
}
