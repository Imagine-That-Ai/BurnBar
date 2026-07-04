using System;
using System.Collections.Generic;
using System.Globalization;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Read-only aggregates over <c>token_usage</c> for Dashboard tiles and dev-host proof.
/// Parse/upsert of rows remains on the Swift Engine path (B0 spike:
/// <c>swift run --package-path OpenBurnBarCore OpenBurnBarG2ParserParity</c>) until an
/// in-process Swift Engine C-ABI binding lands.
/// </summary>
public static class TokenUsageReadSeam
{
    /// <summary>Total <c>cost</c> for rows whose <c>createdAt</c> falls in the current UTC calendar month.</summary>
    public static double SumCostCurrentUtcMonth(SqliteConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        DateTime utcNow = DateTime.UtcNow;
        string monthStart = new DateTime(utcNow.Year, utcNow.Month, 1, 0, 0, 0, DateTimeKind.Utc)
            .ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);

        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT COALESCE(SUM(cost), 0)
            FROM token_usage
            WHERE createdAt >= $monthStart
            """;
        command.Parameters.AddWithValue("$monthStart", monthStart);
        object? scalar = command.ExecuteScalar();
        return scalar is null or DBNull ? 0 : Convert.ToDouble(scalar, CultureInfo.InvariantCulture);
    }

    /// <summary>Sum of <c>totalTokens</c> across all rows (dashboard token headline).</summary>
    public static long SumTotalTokens(SqliteConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COALESCE(SUM(totalTokens), 0) FROM token_usage";
        object? scalar = command.ExecuteScalar();
        return scalar is null or DBNull ? 0 : Convert.ToInt64(scalar, CultureInfo.InvariantCulture);
    }

    /// <summary>Distinct session count (dashboard sessions headline).</summary>
    public static long CountDistinctSessions(SqliteConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(DISTINCT sessionId) FROM token_usage";
        object? scalar = command.ExecuteScalar();
        return scalar is null or DBNull ? 0 : Convert.ToInt64(scalar, CultureInfo.InvariantCulture);
    }

    /// <summary>Most recent rows by <c>createdAt</c> for inspection after a parser write.</summary>
    public static IReadOnlyList<TokenUsageRecord> ListRecent(SqliteConnection connection, int limit = 20)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (limit <= 0)
        {
            return Array.Empty<TokenUsageRecord>();
        }

        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT id, provider, sessionId, projectName, model,
                   inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                   reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                   usageSource, sourceDeviceId, sourceDeviceName, isRemote,
                   providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                   provenanceMethod, provenanceConfidence, estimatorVersion, parentRequestID
            FROM token_usage
            ORDER BY createdAt DESC
            LIMIT $limit
            """;
        command.Parameters.AddWithValue("$limit", limit);

        var rows = new List<TokenUsageRecord>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(ReadRow(reader));
        }

        return rows;
    }

    private static TokenUsageRecord ReadRow(SqliteDataReader reader)
    {
        return new TokenUsageRecord
        {
            Id = reader.GetString(0),
            Provider = reader.GetString(1),
            SessionId = reader.GetString(2),
            ProjectName = reader.GetString(3),
            Model = reader.GetString(4),
            InputTokens = reader.GetInt64(5),
            OutputTokens = reader.GetInt64(6),
            CacheCreationTokens = reader.GetInt64(7),
            CacheReadTokens = reader.GetInt64(8),
            ReasoningTokens = reader.GetInt64(9),
            TotalTokens = reader.GetInt64(10),
            Cost = reader.GetDouble(11),
            StartTime = reader.GetString(12),
            EndTime = reader.GetString(13),
            CreatedAt = reader.GetString(14),
            UsageSource = reader.IsDBNull(15) ? "measured" : reader.GetString(15),
            SourceDeviceId = reader.IsDBNull(16) ? null : reader.GetString(16),
            SourceDeviceName = reader.IsDBNull(17) ? null : reader.GetString(17),
            IsRemote = !reader.IsDBNull(18) && reader.GetInt64(18) != 0,
            ProviderID = reader.IsDBNull(19) ? null : reader.GetString(19),
            ProviderAccountID = reader.IsDBNull(20) ? null : reader.GetString(20),
            ProviderAccountLabel = reader.IsDBNull(21) ? null : reader.GetString(21),
            ProviderAccountSource = reader.IsDBNull(22) ? null : reader.GetString(22),
            ProvenanceMethod = reader.IsDBNull(23) ? "api" : reader.GetString(23),
            ProvenanceConfidence = reader.IsDBNull(24) ? "exact" : reader.GetString(24),
            EstimatorVersion = reader.IsDBNull(25) ? "win-readseam-1" : reader.GetString(25),
            ParentRequestID = reader.IsDBNull(26) ? null : reader.GetString(26),
        };
    }
}