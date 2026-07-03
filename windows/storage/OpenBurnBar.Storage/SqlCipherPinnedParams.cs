using System;

namespace OpenBurnBar.Storage;

/// <summary>
/// The pinned SQLCipher-4 byte-compat contract the Windows build must reproduce
/// to read AND write the Mac-produced encrypted database.
/// </summary>
/// <remarks>
/// Traced to <c>decisions/sqlcipher-params.md</c> /
/// <c>AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-params-observed.json</c>
/// (read back from the live SQLCipher.swift 4.16.0 binary the Mac links). The Mac
/// keys the shared file in <b>passphrase mode</b> (<c>db.usePassphrase</c> /
/// <c>sqlite3_key</c> with UTF-8 passphrase bytes, PBKDF2 derivation) — NOT raw-key
/// mode — in both cipher stacks:
/// <list type="bullet">
///   <item><c>AgentLens/Services/DataStore/DatabaseEncryptionService.makeConfiguration</c> (app / GRDB), and</item>
///   <item><c>OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonDatabaseCipher</c> (daemon / raw sqlite3).</item>
/// </list>
/// The crypto <i>provider</i> may differ (Mac CommonCrypto vs. the Windows/bundle
/// OpenSSL build) — the ciphertext format is defined by the KDF/HMAC/page
/// parameters below, not the provider — so a Windows SQLCipher that reproduces
/// these values reads and writes the Mac file byte-for-byte.
/// </remarks>
public static class SqlCipherPinnedParams
{
    /// <summary>SQLCipher-4 default page size (<c>PRAGMA cipher_page_size</c>).</summary>
    public const int CipherPageSize = 4096;

    /// <summary>SQLCipher-4 default PBKDF2 work factor (<c>PRAGMA kdf_iter</c>).</summary>
    public const int KdfIter = 256_000;

    /// <summary>SQLCipher-4 default per-page HMAC (<c>PRAGMA cipher_hmac_algorithm</c>).</summary>
    public const string HmacAlgorithm = "HMAC_SHA512";

    /// <summary>SQLCipher-4 default key-derivation function (<c>PRAGMA cipher_kdf_algorithm</c>).</summary>
    public const string KdfAlgorithm = "PBKDF2_HMAC_SHA512";

    /// <summary>
    /// SQLCipher-4 compatibility profile. <c>cipher_compatibility</c> is a
    /// write-only PRAGMA (it cannot be read back), so it is asserted indirectly
    /// through the four readable parameters above, which together <i>are</i> the
    /// "compatibility = 4" profile.
    /// </summary>
    public const int CipherCompatibility = 4;

    /// <summary>
    /// The fixed, NON-SECRET passphrase that keys the committed DB byte-compat
    /// fixture. It exists only so the Mac validator and this Windows read/write
    /// seam can open the same committed encrypted file; it keys no real user data.
    /// Documented in the fixture README + <c>decisions/sqlcipher-params.md</c>.
    /// </summary>
    public const string FixturePassphrase = "OBB-WinPort-DBByteCompat-Fixture-Key-v53-000=";

    /// <summary>
    /// Validate that <paramref name="passphrase"/> contains only the base64
    /// alphabet plus <c>-</c> before it is interpolated into a single-quoted
    /// <c>PRAGMA key = '…'</c> literal. None of these characters can escape a
    /// single-quoted SQL string literal, so injection is impossible. This mirrors
    /// <c>DatabaseEncryptionService.validateEncryptionKey</c> /
    /// <c>BurnBarDaemonDatabaseCipher</c>'s charset guard exactly, keeping the
    /// keying paths interchangeable.
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
}
