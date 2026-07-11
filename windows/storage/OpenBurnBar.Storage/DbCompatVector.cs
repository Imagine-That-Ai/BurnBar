using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// The Windows counterpart of the macOS <c>DatabaseByteCompatVector</c>
/// (VAL-P0-DB-009). It recomputes, byte-for-byte, the two things the committed
/// vector pins over an <i>opened</i> encrypted database:
///
///   1. the <b>schema hash</b> — SHA-256 over the normalized, ordered
///      <c>sqlite_master</c> DDL, and
///   2. the <b>FTS5 <c>bm25()</c>/<c>snippet()</c> row set</b> for a fixed set of
///      <c>MATCH</c> probes (porter stemming, case-folding, multi-column indexing,
///      rank order).
///
/// Both algorithms mirror the Swift generator exactly so the same fixture yields
/// the same hash + vector on Mac and Windows. This is the R2 kill-risk oracle
/// (VAL-P0-DB-010): reproducing the committed vector against the committed Mac
/// file is the proof that byte-compat holds.
/// </summary>
public static class DbCompatVector
{
    /// <summary>
    /// The canonical FTS5 probe set, frozen in the committed vector and mirrored
    /// from <c>DatabaseByteCompatVector.ftsQueries</c>. Order is significant — the
    /// vector's <c>ftsQueries</c> array is compared position-by-position.
    /// </summary>
    public static readonly IReadOnlyList<(string Label, string Match)> Probes = new[]
    {
        ("porter-stem-run", "run"),
        ("case-fold-title", "GAMMA"),
        ("fulltext-database", "database"),
        ("porter-stem-shoe", "shoe"),
    };

    /// <summary>
    /// SHA-256 over the normalized, ordered <c>sqlite_master</c> DDL — the schema
    /// hash the vector pins. Only rows with non-null <c>sql</c> are hashed (drops
    /// SQLite-internal auto-indexes) and <c>sqlite_%</c> internal names are
    /// excluded. Each statement is outer-trimmed and joined with <c>\n</c>, exactly
    /// like <c>DatabaseByteCompatVector.computeSchemaHash</c>.
    /// </summary>
    public static string ComputeSchemaHash(SqliteConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);

        var statements = new List<string>();
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "SELECT sql FROM sqlite_master "
                + "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
                + "ORDER BY type, name;";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (!reader.IsDBNull(0))
                {
                    statements.Add(reader.GetString(0).Trim());
                }
            }
        }

        var canonical = string.Join("\n", statements);
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(canonical));
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    /// <summary>
    /// Run the canonical FTS probe set against an opened database and return the
    /// observed vector. Mirrors <c>DatabaseByteCompatVector.runFTSQueries</c>:
    /// <c>bm25(conversations_fts)</c> ranking, <c>snippet(conversations_fts, 1, …)</c>,
    /// <c>ORDER BY rank ASC</c>, <c>deletedAt IS NULL</c>.
    /// </summary>
    public static IReadOnlyList<FtsQueryVector> RunFtsVector(SqliteConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);

        var vectors = new List<FtsQueryVector>();
        foreach (var (label, match) in Probes)
        {
            var rows = new List<FtsRowVector>();
            using var command = connection.CreateCommand();
            command.CommandText =
                "SELECT c.id AS id, "
                + "bm25(conversations_fts) AS rank, "
                + "snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip "
                + "FROM conversations_fts "
                + "JOIN conversations AS c ON c.rowid = conversations_fts.rowid "
                + "WHERE conversations_fts MATCH $match AND c.deletedAt IS NULL "
                + "ORDER BY rank ASC;";
            command.Parameters.AddWithValue("$match", match);
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                rows.Add(new FtsRowVector
                {
                    ConversationId = reader.IsDBNull(0) ? string.Empty : reader.GetString(0),
                    Snippet = reader.IsDBNull(2) ? string.Empty : reader.GetString(2),
                });
            }

            vectors.Add(new FtsQueryVector { Label = label, Match = match, OrderedRows = rows });
        }

        return vectors;
    }

    /// <summary>Deserialize a committed <c>openburnbar-db-compat-vector.json</c> file.</summary>
    public static Vector LoadVector(string vectorJsonPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(vectorJsonPath);
        var json = File.ReadAllText(vectorJsonPath);
        return LoadVectorFromJson(json);
    }

    /// <summary>Deserialize a committed vector from a JSON string.</summary>
    public static Vector LoadVectorFromJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        var vector = JsonSerializer.Deserialize(json, DbCompatJsonContext.Default.Vector);
        return vector ?? throw new InvalidOperationException("DB-compat vector JSON deserialized to null.");
    }

    /// <summary>
    /// Open the encrypted database, recompute the schema hash + FTS vector, and
    /// diff them against a committed vector. The returned report is
    /// <see cref="ByteCompatReport.Passed"/> only when the object count is
    /// positive, the schema hash matches, and every FTS probe's ordered row set
    /// matches exactly.
    /// </summary>
    public static ByteCompatReport Verify(OpenBurnBarStorage storage, Vector expected)
    {
        ArgumentNullException.ThrowIfNull(storage);
        ArgumentNullException.ThrowIfNull(expected);

        var connection = storage.Connection;
        var objectCount = storage.CountSchemaObjects();
        var actualHash = ComputeSchemaHash(connection);
        var actualFts = RunFtsVector(connection);

        var hashMatches = string.Equals(actualHash, expected.SchemaHashSha256, StringComparison.OrdinalIgnoreCase);
        var ftsMatches = FtsVectorsEqual(actualFts, expected.FtsQueries);

        return new ByteCompatReport(
            ObjectCount: objectCount,
            ExpectedSchemaHash: expected.SchemaHashSha256,
            ActualSchemaHash: actualHash,
            SchemaHashMatches: hashMatches,
            FtsRowSetMatches: ftsMatches,
            ActualFtsQueries: actualFts);
    }

    private static bool FtsVectorsEqual(
        IReadOnlyList<FtsQueryVector> actual,
        IReadOnlyList<FtsQueryVector> expected)
    {
        if (actual.Count != expected.Count)
        {
            return false;
        }

        for (var i = 0; i < actual.Count; i++)
        {
            var a = actual[i];
            var e = expected[i];
            if (!string.Equals(a.Label, e.Label, StringComparison.Ordinal)
                || !string.Equals(a.Match, e.Match, StringComparison.Ordinal)
                || a.OrderedRows.Count != e.OrderedRows.Count)
            {
                return false;
            }

            for (var j = 0; j < a.OrderedRows.Count; j++)
            {
                if (!string.Equals(a.OrderedRows[j].ConversationId, e.OrderedRows[j].ConversationId, StringComparison.Ordinal)
                    || !string.Equals(a.OrderedRows[j].Snippet, e.OrderedRows[j].Snippet, StringComparison.Ordinal))
                {
                    return false;
                }
            }
        }

        return true;
    }

    // MARK: - Committed vector shape (mirrors openburnbar-db-compat-vector.json)

    /// <summary>The committed DB-compat vector.</summary>
    public sealed class Vector
    {
        [JsonPropertyName("sqlcipherPin")]
        public string SqlcipherPin { get; set; } = string.Empty;

        [JsonPropertyName("schemaEndpoint")]
        public string SchemaEndpoint { get; set; } = string.Empty;

        [JsonPropertyName("migrationCount")]
        public int MigrationCount { get; set; }

        [JsonPropertyName("schemaHashSHA256")]
        public string SchemaHashSha256 { get; set; } = string.Empty;

        [JsonPropertyName("ftsQueries")]
        public List<FtsQueryVector> FtsQueries { get; set; } = new();
    }

    /// <summary>One FTS5 <c>MATCH</c> probe result.</summary>
    public sealed class FtsQueryVector
    {
        [JsonPropertyName("label")]
        public string Label { get; set; } = string.Empty;

        [JsonPropertyName("match")]
        public string Match { get; set; } = string.Empty;

        [JsonPropertyName("orderedRows")]
        public List<FtsRowVector> OrderedRows { get; set; } = new();
    }

    /// <summary>One matched row: conversation id + <c>snippet()</c> markup.</summary>
    public sealed class FtsRowVector
    {
        [JsonPropertyName("conversationID")]
        public string ConversationId { get; set; } = string.Empty;

        [JsonPropertyName("snippet")]
        public string Snippet { get; set; } = string.Empty;
    }
}

/// <summary>The result of a byte-compat verification run.</summary>
public sealed record ByteCompatReport(
    int ObjectCount,
    string ExpectedSchemaHash,
    string ActualSchemaHash,
    bool SchemaHashMatches,
    bool FtsRowSetMatches,
    IReadOnlyList<DbCompatVector.FtsQueryVector> ActualFtsQueries)
{
    /// <summary>True only when the object count is positive, the schema hash matches, and the FTS row set matches.</summary>
    public bool Passed => ObjectCount > 0 && SchemaHashMatches && FtsRowSetMatches;
}

/// <summary>Source-generated JSON context for trim-safe, reflection-free (de)serialization.</summary>
[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(DbCompatVector.Vector))]
internal sealed partial class DbCompatJsonContext : JsonSerializerContext
{
}
