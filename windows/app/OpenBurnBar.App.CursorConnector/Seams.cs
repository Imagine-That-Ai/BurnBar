using System;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace OpenBurnBar.App.CursorConnector;

// ── Injectable seams ─────────────────────────────────────────────────────────
//
// The Swift oracle reaches straight for platform singletons — `Date.init`,
// `FileHandle`, `SecRandomCopyBytes`, `KeychainStore`, the on-disk `state.vscdb`.
// Windows parity keeps every one of those behind a seam so the portable core is
// provable via `dotnet test` on the macOS authoring host and the real
// DPAPI/FileSystemWatcher/SQLite halves drop in unchanged as the deferred
// OpenBurnBar.App.CursorConnector.Windows adapter (bucket B).

/// <summary>
/// Injectable clock. Windows peer of the Swift <c>now: () -&gt; Date</c> closures
/// (e.g. <c>RoutedClientConfigSyncService.now</c>) and the ambient <c>Date()</c>
/// reads across <c>CursorConnectorManager</c>. UTC everywhere.
/// </summary>
public interface IConnectorClock
{
    /// <summary>The current instant.</summary>
    DateTimeOffset UtcNow { get; }
}

/// <summary>Wall-clock <see cref="IConnectorClock"/>.</summary>
public sealed class SystemConnectorClock : IConnectorClock
{
    /// <summary>Shared wall-clock instance.</summary>
    public static readonly SystemConnectorClock Instance = new();

    /// <inheritdoc />
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
}

/// <summary>
/// Secret store seam. Windows peer of <c>KeychainStore</c>
/// (AgentLens/Services/CursorConnector/KeychainStore.swift). The Mac backs this
/// with the login Keychain (<c>kSecClassGenericPassword</c>, non-interactive
/// reads); Windows backs it with DPAPI/CNG in the deferred .Windows adapter.
///
/// <para>Contract mirrors <c>KeychainStore.credentialIfPresent</c>: a genuinely
/// absent secret returns <c>null</c>; a broken/locked store is the adapter's
/// concern to log — the portable core treats <c>null</c> as "no secret".</para>
/// </summary>
public interface ISecretStore
{
    /// <summary>Reads the secret for <paramref name="account"/>, or <c>null</c> when absent/unreadable.</summary>
    string? TryRead(string account);

    /// <summary>Writes (or overwrites) the secret for <paramref name="account"/>.</summary>
    void Set(string account, string value);

    /// <summary>Deletes the secret for <paramref name="account"/> (absent is success).</summary>
    void Delete(string account);
}

/// <summary>
/// Append-only log stream seam. Windows peer of the <c>FileHandle</c> reads in
/// <c>CursorConnectorLogStreamManager</c>: the manager tracks a byte offset and
/// asks the source for the file's current length plus the bytes from a given
/// offset to the end. The real implementation opens the live proxy/usage log; the
/// test fake serves recorded fixture bytes.
/// </summary>
public interface ILogStreamSource
{
    /// <summary>Whether the backing file currently exists.</summary>
    bool Exists(string path);

    /// <summary>The backing file's current byte length, or <c>null</c> when it cannot be probed.</summary>
    long? Length(string path);

    /// <summary>Reads the bytes from <paramref name="offset"/> to end-of-file.</summary>
    byte[] ReadFrom(string path, long offset);
}

/// <summary>
/// Cursor <c>state.vscdb</c> ItemTable key/value seam. Windows peer of the
/// SQLite reads/writes in <c>backupAndApplyCursorSettings</c>/
/// <c>restoreCursorSettings</c>. The portable snapshot→mutate→restore state
/// machine (CursorSettingsApplier) rides this seam; the real
/// Microsoft.Data.Sqlite ItemTable read/write (same stack as
/// CursorStateDbReader) is the deferred .Windows half.
/// </summary>
public interface ICursorStateStore
{
    /// <summary>Reads an ItemTable value, or <c>null</c> when the key is absent.</summary>
    string? TryReadItem(string key);

    /// <summary>Upserts an ItemTable value (<c>INSERT OR REPLACE</c>).</summary>
    void WriteItem(string key, string value);
}

/// <summary>
/// Random-token seam. Windows peer of <c>SecRandomCopyBytes</c> (rotation token,
/// session token, broker bearer token). The system implementation uses
/// <see cref="RandomNumberGenerator"/>; tests inject a deterministic source.
/// </summary>
public interface IRandomTokenSource
{
    /// <summary>Returns <paramref name="byteCount"/> cryptographically-random bytes.</summary>
    byte[] NextBytes(int byteCount);
}

/// <summary>CSPRNG-backed <see cref="IRandomTokenSource"/>.</summary>
public sealed class SystemRandomTokenSource : IRandomTokenSource
{
    /// <summary>Shared CSPRNG instance.</summary>
    public static readonly SystemRandomTokenSource Instance = new();

    /// <inheritdoc />
    public byte[] NextBytes(int byteCount)
    {
        if (byteCount < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(byteCount));
        }

        var bytes = new byte[byteCount];
        RandomNumberGenerator.Fill(bytes);
        return bytes;
    }
}

/// <summary>
/// Lowercase-hex helper mirroring the Swift
/// <c>bytes.map { String(format: "%02x", $0) }.joined()</c> token encoding.
/// </summary>
public static class HexToken
{
    /// <summary>Encodes <paramref name="bytes"/> as lowercase hex.</summary>
    public static string Encode(IReadOnlyList<byte> bytes)
    {
        if (bytes is null)
        {
            throw new ArgumentNullException(nameof(bytes));
        }

        var chars = new char[bytes.Count * 2];
        for (var i = 0; i < bytes.Count; i++)
        {
            var b = bytes[i];
            chars[i * 2] = NibbleToHex(b >> 4);
            chars[(i * 2) + 1] = NibbleToHex(b & 0xF);
        }

        return new string(chars);
    }

    private static char NibbleToHex(int nibble) =>
        (char)(nibble < 10 ? '0' + nibble : 'a' + (nibble - 10));
}
