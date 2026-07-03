using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// The real Windows storage layer: opens the Mac-produced SQLCipher database with
/// the pinned compatibility-4 cipher profile + passphrase key and exposes a
/// read-only, DataStore-shaped API over it (<see cref="IConversationReadStore"/>).
///
/// This is the Windows side of the DataStore seam the Engine calls through the
/// PAL. It uses the SQLCipher C library (SQLitePCLRaw.bundle_e_sqlcipher) behind
/// the ADO.NET provider — the master plan's sanctioned "raw-SQLCipher-C + a thin
/// data layer reproducing the exact pinned config" fallback for R2, in managed
/// form. Byte-compat is proven by <see cref="DbCompatVector"/> against the
/// committed fixture + vector (VAL-P0-DB-010).
///
/// Not thread-safe: hold one instance per logical reader (a single keyed
/// connection). Dispose to close the connection.
/// </summary>
public sealed class OpenBurnBarStorage : IConversationReadStore, IDisposable
{
    private readonly SqliteConnection _connection;
    private bool _disposed;

    private OpenBurnBarStorage(SqliteConnection connection)
    {
        _connection = connection;
    }

    /// <summary>
    /// Open the encrypted database at <paramref name="databasePath"/> read-only,
    /// keyed with <paramref name="passphrase"/> and pinned to the compatibility-4
    /// profile. The connection is verified live (<c>PRAGMA cipher_version</c>) so a
    /// wrong key / non-cipher build fails loudly instead of returning garbage.
    /// </summary>
    public static OpenBurnBarStorage OpenReadOnly(string databasePath, string passphrase)
    {
        ArgumentException.ThrowIfNullOrEmpty(databasePath);
        ArgumentNullException.ThrowIfNull(passphrase);

        SqlCipherParameters.EnsureProviderInitialized();

        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString();

        var connection = new SqliteConnection(connectionString);
        try
        {
            connection.Open();
            SqlCipherParameters.KeyAndPin(connection, passphrase);

            // Force a real page read so a bad key / param mismatch surfaces here
            // (SQLCipher only attempts decryption on first content access).
            _ = SqlCipherParameters.ReadScalarString(connection, "SELECT count(*) FROM sqlite_master;");
            return new OpenBurnBarStorage(connection);
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    /// <summary>The live keyed connection, for advanced callers (e.g. the byte-compat vector).</summary>
    public SqliteConnection Connection
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _connection;
        }
    }

    /// <summary>Read the live SQLCipher parameters as open-time evidence.</summary>
    public ObservedCipherParams ReadObservedCipherParams()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return new ObservedCipherParams(
            CipherVersion: SqlCipherParameters.ReadScalarString(_connection, "PRAGMA cipher_version;") ?? string.Empty,
            CipherProvider: SqlCipherParameters.ReadScalarString(_connection, "PRAGMA cipher_provider;") ?? string.Empty,
            CipherPageSize: ReadScalarInt("PRAGMA cipher_page_size;"),
            KdfIter: ReadScalarInt("PRAGMA kdf_iter;"),
            HmacAlgorithm: SqlCipherParameters.ReadScalarString(_connection, "PRAGMA cipher_hmac_algorithm;") ?? string.Empty,
            KdfAlgorithm: SqlCipherParameters.ReadScalarString(_connection, "PRAGMA cipher_kdf_algorithm;") ?? string.Empty);
    }

    /// <inheritdoc />
    public int CountSchemaObjects()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return ReadScalarInt("SELECT count(*) FROM sqlite_master;");
    }

    /// <inheritdoc />
    public IReadOnlyList<SchemaObject> ListSchemaObjects()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var objects = new List<SchemaObject>();
        using var command = _connection.CreateCommand();
        command.CommandText =
            "SELECT type, name, sql FROM sqlite_master ORDER BY type, name;";
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            objects.Add(new SchemaObject(
                Type: reader.GetString(0),
                Name: reader.GetString(1),
                Sql: reader.IsDBNull(2) ? null : reader.GetString(2)));
        }

        return objects;
    }

    /// <inheritdoc />
    public ConversationRecord? GetConversation(string id)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(id);

        using var command = _connection.CreateCommand();
        command.CommandText =
            "SELECT id, provider, sessionId, projectName, inferredTaskTitle, fullText, indexedAt, messageCount "
            + "FROM conversations WHERE id = $id AND deletedAt IS NULL;";
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadConversation(reader) : null;
    }

    /// <inheritdoc />
    public IReadOnlyList<ConversationRecord> ListConversations(int limit = 50)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        var rows = new List<ConversationRecord>();
        using var command = _connection.CreateCommand();
        command.CommandText =
            "SELECT id, provider, sessionId, projectName, inferredTaskTitle, fullText, indexedAt, messageCount "
            + "FROM conversations WHERE deletedAt IS NULL "
            + "ORDER BY COALESCE(indexedAt, '') DESC, id ASC LIMIT $limit;";
        command.Parameters.AddWithValue("$limit", limit);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(ReadConversation(reader));
        }

        return rows;
    }

    /// <inheritdoc />
    public IReadOnlyList<ConversationSearchResult> SearchConversationsFts(string match, int limit = 50)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(match);

        var results = new List<ConversationSearchResult>();
        using var command = _connection.CreateCommand();
        command.CommandText =
            "SELECT c.id, c.provider, c.sessionId, c.projectName, c.inferredTaskTitle, c.fullText, c.indexedAt, c.messageCount, "
            + "bm25(conversations_fts) AS rank, "
            + "snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip "
            + "FROM conversations_fts "
            + "JOIN conversations AS c ON c.rowid = conversations_fts.rowid "
            + "WHERE conversations_fts MATCH $match AND c.deletedAt IS NULL "
            + "ORDER BY rank ASC LIMIT $limit;";
        command.Parameters.AddWithValue("$match", match);
        command.Parameters.AddWithValue("$limit", limit);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var conversation = ReadConversation(reader);
            var rank = reader.GetDouble(8);
            var snippet = reader.IsDBNull(9) ? string.Empty : reader.GetString(9);
            results.Add(new ConversationSearchResult(conversation, snippet, rank));
        }

        return results;
    }

    private static ConversationRecord ReadConversation(SqliteDataReader reader)
    {
        return new ConversationRecord(
            Id: reader.GetString(0),
            Provider: reader.GetString(1),
            SessionId: reader.GetString(2),
            ProjectName: reader.GetString(3),
            InferredTaskTitle: reader.GetString(4),
            FullText: reader.GetString(5),
            IndexedAt: reader.IsDBNull(6) ? null : reader.GetString(6),
            MessageCount: reader.IsDBNull(7) ? 0 : reader.GetInt64(7));
    }

    private int ReadScalarInt(string sql)
    {
        var value = SqlCipherParameters.ReadScalarString(_connection, sql);
        return int.TryParse(value, out var parsed) ? parsed : -1;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _connection.Dispose();
    }
}
