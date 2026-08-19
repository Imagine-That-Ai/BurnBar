using System;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// The pinned SQLCipher byte-compat contract the Windows storage layer MUST
/// reproduce to open the Mac-produced database (R2). These values are the
/// SQLCipher <c>cipher_compatibility = 4</c> profile as shipped by
/// SQLCipher.swift 4.16.0 on macOS, frozen in
/// <c>decisions/sqlcipher-params.md</c> and evidenced by
/// <c>AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-params-observed.json</c>.
///
/// The macOS app keys the database in <b>passphrase mode</b>
/// (<c>Database.usePassphrase</c> → <c>sqlite3_key</c> with the UTF-8 bytes of the
/// passphrase, PBKDF2 derivation — NOT raw-key mode) and never writes the cipher
/// PRAGMAs, inheriting the compile-time defaults of the linked SQLCipher build.
/// The Windows side sets them <b>explicitly</b> so byte-compat is enforced at open
/// time and survives any future default drift on either platform.
/// </summary>
public static class SqlCipherParameters
{
    /// <summary>SQLCipher 4 default page size.</summary>
    public const int CipherPageSize = 4096;

    /// <summary>SQLCipher 4 default PBKDF2 work factor.</summary>
    public const int KdfIter = 256_000;

    /// <summary>SQLCipher 4 default per-page HMAC.</summary>
    public const string HmacAlgorithm = "HMAC_SHA512";

    /// <summary>SQLCipher 4 default key-derivation function.</summary>
    public const string KdfAlgorithm = "PBKDF2_HMAC_SHA512";

    /// <summary>
    /// SQLCipher 4 default cipher-compatibility profile. <c>cipher_compatibility</c>
    /// is a <b>write-only</b> PRAGMA (it cannot be read back), so it is asserted
    /// indirectly through the four readable parameters above, which together
    /// <i>are</i> the "compatibility = 4" profile.
    /// </summary>
    public const int CipherCompatibility = 4;

    /// <summary>
    /// The fixed, <b>non-secret</b> test passphrase that keys the committed
    /// byte-compat fixture (<c>openburnbar-db-compat-v64.sqlcipher</c>). It exists so
    /// the macOS generator and this Windows open-side check open the <i>same</i>
    /// committed encrypted file; it keys only that throwaway fixture, never real
    /// user data. Documented in the fixture README and
    /// <c>decisions/sqlcipher-params.md</c>. Real deployments source the passphrase
    /// from the platform secret store via the PAL — this constant is test-only.
    /// </summary>
    public const string FixturePassphrase = "OBB-WinPort-DBByteCompat-Fixture-Key-v53-000=";

    private static bool _providerInitialized;
    private static readonly object InitLock = new();

    /// <summary>
    /// Register the SQLCipher native provider (idempotent). Microsoft.Data.Sqlite
    /// .Core requires a bundle to be initialized before the first connection;
    /// <c>bundle_e_sqlcipher</c> supplies the SQLCipher-enabled build.
    /// </summary>
    public static void EnsureProviderInitialized()
    {
        if (_providerInitialized)
        {
            return;
        }

        lock (InitLock)
        {
            if (_providerInitialized)
            {
                return;
            }

            SQLitePCL.Batteries_V2.Init();
            _providerInitialized = true;
        }
    }

    /// <summary>
    /// Validate that <paramref name="passphrase"/> contains only the base64
    /// alphabet plus <c>-</c> before it is interpolated into a single-quoted
    /// <c>PRAGMA key = '…'</c> literal. None of these characters can escape a
    /// single-quoted SQL string literal, so injection is impossible. This mirrors
    /// <c>DatabaseEncryptionService.validateEncryptionKey</c> /
    /// <c>BurnBarDaemonDatabaseCipher</c>'s charset guard exactly, keeping the
    /// Mac and Windows keying paths interchangeable. (The read seam's
    /// <see cref="KeyAndPin"/> additionally doubles embedded quotes, so it accepts
    /// arbitrary passphrases; the write opener validates up front instead.)
    /// </summary>
    /// <exception cref="ArgumentException">The passphrase is empty or contains a disallowed character.</exception>
    public static void ValidatePassphrase(string passphrase)
    {
        if (string.IsNullOrEmpty(passphrase))
        {
            throw new ArgumentException("Encryption passphrase must not be empty.", nameof(passphrase));
        }

        foreach (char c in passphrase)
        {
            bool ok = (c >= 'A' && c <= 'Z')
                || (c >= 'a' && c <= 'z')
                || (c >= '0' && c <= '9')
                || c == '+' || c == '/' || c == '=' || c == '-';
            if (!ok)
            {
                throw new ArgumentException(
                    "Encryption passphrase contains a character outside the base64 alphabet + '-'; "
                    + "refusing to interpolate it into a PRAGMA key literal.",
                    nameof(passphrase));
            }
        }
    }

    /// <summary>
    /// Key an already-open connection and pin the compatibility-4 cipher profile,
    /// in the SQLCipher-required order: <c>PRAGMA key</c> first, then
    /// <c>cipher_compatibility = 4</c> and the individual page/KDF pins, then a
    /// hard <c>PRAGMA cipher_version</c> self-check that mirrors the macOS
    /// <c>DatabaseEncryptionService</c> guard against a silent plaintext no-op.
    ///
    /// SQLite does not allow bound parameters in a <c>PRAGMA</c>, so the passphrase
    /// is inlined as a single-quoted SQL string literal with embedded quotes
    /// doubled. A quoted (non-<c>x'…'</c>) value is treated as a <b>passphrase</b>
    /// (PBKDF2 derivation), matching the macOS <c>Database.usePassphrase</c> /
    /// <c>sqlite3_key</c> keying — NOT raw-key mode.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// SQLCipher is not active in this build (a non-cipher SQLite would make
    /// <c>PRAGMA key</c> a silent no-op and the Mac file unreadable).
    /// </exception>
    public static void KeyAndPin(SqliteConnection connection, string passphrase)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(passphrase);

        var escaped = passphrase.Replace("'", "''", StringComparison.Ordinal);
        ExecutePragma(connection, $"PRAGMA key = '{escaped}';");

        ExecutePragma(connection, $"PRAGMA cipher_compatibility = {CipherCompatibility};");
        ExecutePragma(connection, $"PRAGMA cipher_page_size = {CipherPageSize};");
        ExecutePragma(connection, $"PRAGMA kdf_iter = {KdfIter};");

        var cipherVersion = ReadScalarString(connection, "PRAGMA cipher_version;");
        if (string.IsNullOrEmpty(cipherVersion))
        {
            throw new InvalidOperationException(
                "SQLCipher is not active in this build (PRAGMA cipher_version was empty); "
                + "the Mac-produced encrypted database cannot be opened. Ensure "
                + "SQLitePCLRaw.bundle_e_sqlcipher is the registered provider.");
        }

        if (!cipherVersion.StartsWith("4.", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"cipher_version must be a SQLCipher 4.x string for byte-compat; got '{cipherVersion}'.");
        }
    }

    private static void ExecutePragma(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    internal static string? ReadScalarString(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar()?.ToString();
    }
}
