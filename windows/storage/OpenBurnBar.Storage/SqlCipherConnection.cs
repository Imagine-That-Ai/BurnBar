using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Canonical opener for the shared SQLCipher-encrypted OpenBurnBar database on
/// Windows, plus the schema-hash + migration-marker readers the byte-compat
/// contract pins.
/// </summary>
/// <remarks>
/// This is the Windows peer of the Mac keying path
/// (<c>DatabaseEncryptionService.makeConfiguration</c>) and the daemon's second
/// cipher stack (<c>BurnBarDaemonDatabaseCipher</c>). It keys in passphrase mode,
/// self-checks that the SQLCipher codec is genuinely active (catching the
/// historical "PRAGMA key is a plaintext no-op" regression), and — when asked —
/// asserts the connection resolved to the pinned SQLCipher-4 parameters so a
/// drifted Windows SQLCipher build fails loudly instead of silently writing a
/// file the Mac can no longer read.
/// </remarks>
public static class SqlCipherConnection
{
    /// <summary>The 16-byte magic header every PLAINTEXT SQLite 3 file begins with.</summary>
    private static readonly byte[] PlaintextSqliteMagic =
        Encoding.ASCII.GetBytes("SQLite format 3\0");

    /// <summary>
    /// Open a keyed connection to the SQLCipher database at <paramref name="path"/>.
    /// The passphrase is validated and applied as a single-quoted <c>PRAGMA key</c>
    /// literal; the codec is then verified active via a non-empty
    /// <c>PRAGMA cipher_version</c>. Pooling is disabled so the file handle is
    /// released deterministically when the connection is disposed (a copied fixture
    /// can then be reopened/deleted).
    /// </summary>
    /// <exception cref="InvalidOperationException">The SQLCipher codec is not active after keying (wrong build or wrong key).</exception>
    public static SqliteConnection Open(string path, string passphrase)
    {
        SqlCipherParameters.ValidatePassphrase(passphrase);

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false,
        };

        var connection = new SqliteConnection(builder.ConnectionString);
        connection.Open();

        try
        {
            // PRAGMA key does not accept parameter binding; the passphrase was
            // charset-validated above so the single-quoted literal is injection-safe.
            ExecuteNonQuery(connection, $"PRAGMA key = '{passphrase}';");

            string cipherVersion = ReadScalarString(connection, "PRAGMA cipher_version;") ?? string.Empty;
            if (cipherVersion.Length == 0)
            {
                throw new InvalidOperationException(
                    "PRAGMA cipher_version is empty — the SQLCipher codec is not active on this "
                    + "connection (a stock-SQLite build or a plaintext-key no-op).");
            }

            // Touch the schema through the codec so a wrong key fails HERE (as a
            // "file is not a database" / HMAC error) rather than at first read.
            ExecuteNonQuery(connection, "SELECT count(*) FROM sqlite_master;");
        }
        catch
        {
            connection.Dispose();
            throw;
        }

        return connection;
    }

    /// <summary>
    /// Assert the keyed connection resolved to the pinned SQLCipher-4 byte-compat
    /// parameters. <paramref name="cipherVersion"/> is returned for evidence.
    /// </summary>
    /// <exception cref="InvalidOperationException">Any pinned parameter drifted.</exception>
    public static void AssertPinnedParams(SqliteConnection connection, out string cipherVersion)
    {
        cipherVersion = ReadScalarString(connection, "PRAGMA cipher_version;") ?? string.Empty;
        if (!cipherVersion.StartsWith("4.", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"cipher_version must be a SQLCipher 4.x string; got '{cipherVersion}'.");
        }

        RequireInt(connection, "cipher_page_size", SqlCipherParameters.CipherPageSize);
        RequireInt(connection, "kdf_iter", SqlCipherParameters.KdfIter);
        RequireString(connection, "cipher_hmac_algorithm", SqlCipherParameters.HmacAlgorithm);
        RequireString(connection, "cipher_kdf_algorithm", SqlCipherParameters.KdfAlgorithm);
    }

    /// <summary>
    /// SHA-256 (lowercase hex) over the normalized, ordered <c>sqlite_master</c>
    /// DDL — the SCHEMA HASH the DB byte-compat vector pins.
    /// </summary>
    /// <remarks>
    /// Reproduces <c>DatabaseByteCompatVector.computeSchemaHash</c> byte-for-byte:
    /// select every non-null <c>sql</c> whose name is not <c>sqlite_%</c>, ordered
    /// by <c>(type, name)</c>; trim outer whitespace/newlines from each statement;
    /// join with <c>"\n"</c>; UTF-8 SHA-256. The same migrator on Mac and Windows
    /// therefore yields the same bytes and the same hash — so this is the oracle
    /// for "a Windows write did NOT accidentally migrate or corrupt the schema."
    /// </remarks>
    public static string ComputeSchemaHash(SqliteConnection connection)
    {
        var statements = new List<string>();
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "SELECT sql FROM sqlite_master "
                + "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
                + "ORDER BY type, name";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                statements.Add(reader.GetString(0).Trim());
            }
        }

        string canonical = string.Join("\n", statements);
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(canonical));
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    /// <summary>
    /// The last applied migration identifier recorded in GRDB's
    /// <c>grdb_migrations</c> table — the "migration version" marker (e.g.
    /// <c>v57_execution_source_attribution</c>). GRDB tracks applied migrations in this
    /// table rather than <c>PRAGMA user_version</c>, so this — together with
    /// <see cref="ReadUserVersion"/> — is what must survive a Windows write for the
    /// file to stay reopenable + migratable on Mac.
    /// </summary>
    public static string ReadMigrationEndpoint(SqliteConnection connection)
    {
        return ReadScalarString(
            connection,
            "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") ?? string.Empty;
    }

    /// <summary>The count of applied migrations recorded in <c>grdb_migrations</c>.</summary>
    public static long ReadMigrationCount(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT count(*) FROM grdb_migrations";
        return Convert.ToInt64(command.ExecuteScalar());
    }

    /// <summary>The SQLite <c>user_version</c> pragma value.</summary>
    public static long ReadUserVersion(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA user_version;";
        return Convert.ToInt64(command.ExecuteScalar());
    }

    /// <summary>
    /// True when the first 16 bytes of the file at <paramref name="path"/> are NOT
    /// the plaintext SQLite magic header — i.e. the file is genuinely encrypted.
    /// </summary>
    public static bool FileIsEncrypted(string path)
    {
        using var stream = new System.IO.FileStream(
            path,
            System.IO.FileMode.Open,
            System.IO.FileAccess.Read,
            System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete);
        Span<byte> header = stackalloc byte[16];
        int read = stream.Read(header);
        if (read < 16)
        {
            return false;
        }

        return !header.SequenceEqual(PlaintextSqliteMagic);
    }

    private static void RequireInt(SqliteConnection connection, string pragma, int expected)
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA {pragma};";
        long actual = Convert.ToInt64(command.ExecuteScalar());
        if (actual != expected)
        {
            throw new InvalidOperationException(
                $"{pragma} drifted from the pinned SQLCipher-4 default: expected {expected}, got {actual}.");
        }
    }

    private static void RequireString(SqliteConnection connection, string pragma, string expected)
    {
        string actual = ReadScalarString(connection, $"PRAGMA {pragma};") ?? string.Empty;
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"{pragma} drifted from the pinned SQLCipher-4 default: expected '{expected}', got '{actual}'.");
        }
    }

    private static void ExecuteNonQuery(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static string? ReadScalarString(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar()?.ToString();
    }
}
