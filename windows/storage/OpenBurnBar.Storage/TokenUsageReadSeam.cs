using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
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
    /// <summary>
    /// Reads all headline metrics from the same optional UTC floor. A null floor
    /// means all time; bounded windows never mix current-window cost with all-time
    /// tokens or sessions.
    /// </summary>
    public static TokenUsageWindowTotals LoadWindowTotals(
        SqliteConnection connection,
        DateTimeOffset? startUtc)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText = startUtc is null
            ? "SELECT COALESCE(SUM(cost), 0), COALESCE(SUM(totalTokens), 0), COUNT(DISTINCT sessionId) FROM token_usage"
            : "SELECT COALESCE(SUM(cost), 0), COALESCE(SUM(totalTokens), 0), COUNT(DISTINCT sessionId) FROM token_usage WHERE createdAt >= $start";
        if (startUtc is { } start)
        {
            command.Parameters.AddWithValue("$start", FormatTimestamp(start));
        }

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return new TokenUsageWindowTotals(0, 0, 0);
        }

        return new TokenUsageWindowTotals(
            reader.GetDouble(0),
            reader.GetInt64(1),
            reader.GetInt64(2));
    }

    /// <summary>Load the live dashboard/tray aggregate in one bounded set of indexed queries.</summary>
    public static TokenUsageAggregateSnapshot LoadAggregateSnapshot(
        SqliteConnection connection,
        DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(connection);
        DateTimeOffset utcNow = (now ?? DateTimeOffset.UtcNow).ToUniversalTime();
        DateTimeOffset today = new(utcNow.Year, utcNow.Month, utcNow.Day, 0, 0, 0, TimeSpan.Zero);
        DateTimeOffset week = today.AddDays(-6);
        DateTimeOffset month = new(utcNow.Year, utcNow.Month, 1, 0, 0, 0, TimeSpan.Zero);

        double todayCost = SumCostSince(connection, today);
        double weekCost = SumCostSince(connection, week);
        double monthCost = SumCostSince(connection, month);
        long totalTokens = SumLong(connection, "SELECT COALESCE(SUM(totalTokens), 0) FROM token_usage");
        int sessionCount = checked((int)Math.Min(int.MaxValue, SumLong(
            connection,
            "SELECT COUNT(DISTINCT sessionId) FROM token_usage")));
        DateTimeOffset? lastActivity = ReadLastActivity(connection);

        var daily = new double[7];
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                """
                SELECT substr(createdAt, 1, 10), COALESCE(SUM(cost), 0)
                FROM token_usage
                WHERE createdAt >= $start
                GROUP BY substr(createdAt, 1, 10)
                """;
            command.Parameters.AddWithValue("$start", FormatTimestamp(week));
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (DateTimeOffset.TryParse(
                        reader.GetString(0),
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                        out DateTimeOffset day))
                {
                    int index = (int)(day.Date - week.Date).TotalDays;
                    if (index >= 0 && index < daily.Length)
                    {
                        daily[index] = reader.GetDouble(1);
                    }
                }
            }
        }

        return new TokenUsageAggregateSnapshot(
            todayCost,
            weekCost,
            monthCost,
            totalTokens,
            sessionCount,
            lastActivity,
            daily,
            LoadGroupRows(connection, "provider", "provider", 12),
            LoadGroupRows(connection, "model", "provider", 20));
    }

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

    /// <summary>Column list consumed by <see cref="ReadRow"/> — shared by every row-returning query.</summary>
    private const string RowColumns =
        "id, provider, sessionId, projectName, model,\n" +
        "                   inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,\n" +
        "                   reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,\n" +
        "                   usageSource, executionSourceID, executionSourceName,\n" +
        "                   executionSourceKind, executionSourceConfidence,\n" +
        "                   sourceDeviceId, sourceDeviceName, isRemote,\n" +
        "                   providerID, providerAccountID, providerAccountLabel, providerAccountSource,\n" +
        "                   provenanceMethod, provenanceConfidence, estimatorVersion, parentRequestID";

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
                   usageSource, executionSourceID, executionSourceName,
                   executionSourceKind, executionSourceConfidence,
                   sourceDeviceId, sourceDeviceName, isRemote,
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

    /// <summary>
    /// Rows whose <c>startTime</c> falls in <paramref name="startUtc"/> (inclusive) …
    /// <paramref name="endUtcExclusive"/>, ascending — the Calendar surface's fetch
    /// window. Attribution follows the macOS rule (sessions belong to the day their
    /// <c>startTime</c> lands in), so the range filter uses <c>startTime</c>, not
    /// <c>createdAt</c>.
    /// </summary>
    public static IReadOnlyList<TokenUsageRecord> ListInRange(
        SqliteConnection connection,
        DateTimeOffset startUtc,
        DateTimeOffset endUtcExclusive)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (endUtcExclusive <= startUtc)
        {
            return Array.Empty<TokenUsageRecord>();
        }

        using var command = connection.CreateCommand();
        command.CommandText =
            $"""
            SELECT {RowColumns}
            FROM token_usage
            WHERE startTime >= $start AND startTime < $end
            ORDER BY startTime ASC
            """;
        command.Parameters.AddWithValue("$start", FormatTimestamp(startUtc));
        command.Parameters.AddWithValue("$end", FormatTimestamp(endUtcExclusive));

        var rows = new List<TokenUsageRecord>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(ReadRow(reader));
        }

        return rows;
    }

    /// <summary>
    /// Per-session token/cost rollups for a set of session ids — one GROUP BY
    /// query (the SharedUi session list joins these onto session-log records so
    /// rows never display fabricated zero usage). Ids are bound as parameters;
    /// the empty set short-circuits.
    /// </summary>
    public static IReadOnlyDictionary<string, (long TotalTokens, double CostUsd)> LoadSessionTotals(
        SqliteConnection connection,
        IReadOnlyCollection<string> sessionIds)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (sessionIds is null || sessionIds.Count == 0)
        {
            return new Dictionary<string, (long, double)>(StringComparer.Ordinal);
        }

        var names = new List<string>(sessionIds.Count);
        using var command = connection.CreateCommand();
        int index = 0;
        foreach (string id in sessionIds)
        {
            string name = "$sid" + index.ToString(CultureInfo.InvariantCulture);
            names.Add(name);
            command.Parameters.AddWithValue(name, id);
            index += 1;
        }

        command.CommandText =
            $"SELECT sessionId, COALESCE(SUM(totalTokens), 0), COALESCE(SUM(cost), 0)\n" +
            $"FROM token_usage\n" +
            $"WHERE sessionId IN ({string.Join(", ", names)})\n" +
            $"GROUP BY sessionId";

        var totals = new Dictionary<string, (long, double)>(StringComparer.Ordinal);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            totals[reader.GetString(0)] = (reader.GetInt64(1), reader.GetDouble(2));
        }

        return totals;
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
            ExecutionSourceID = reader.IsDBNull(16) ? "unknown" : reader.GetString(16),
            ExecutionSourceName = reader.IsDBNull(17) ? "Unknown" : reader.GetString(17),
            ExecutionSourceKind = reader.IsDBNull(18) ? "unknown" : reader.GetString(18),
            ExecutionSourceConfidence = reader.IsDBNull(19) ? "unknown" : reader.GetString(19),
            SourceDeviceId = reader.IsDBNull(20) ? null : reader.GetString(20),
            SourceDeviceName = reader.IsDBNull(21) ? null : reader.GetString(21),
            IsRemote = !reader.IsDBNull(22) && reader.GetInt64(22) != 0,
            ProviderID = reader.IsDBNull(23) ? null : reader.GetString(23),
            ProviderAccountID = reader.IsDBNull(24) ? null : reader.GetString(24),
            ProviderAccountLabel = reader.IsDBNull(25) ? null : reader.GetString(25),
            ProviderAccountSource = reader.IsDBNull(26) ? null : reader.GetString(26),
            ProvenanceMethod = reader.IsDBNull(27) ? "api" : reader.GetString(27),
            ProvenanceConfidence = reader.IsDBNull(28) ? "exact" : reader.GetString(28),
            EstimatorVersion = reader.IsDBNull(29) ? "win-readseam-1" : reader.GetString(29),
            ParentRequestID = reader.IsDBNull(30) ? null : reader.GetString(30),
        };
    }

    private static double SumCostSince(SqliteConnection connection, DateTimeOffset start)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COALESCE(SUM(cost), 0) FROM token_usage WHERE createdAt >= $start";
        command.Parameters.AddWithValue("$start", FormatTimestamp(start));
        object? scalar = command.ExecuteScalar();
        return scalar is null or DBNull ? 0 : Convert.ToDouble(scalar, CultureInfo.InvariantCulture);
    }

    private static long SumLong(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        object? scalar = command.ExecuteScalar();
        return scalar is null or DBNull ? 0 : Convert.ToInt64(scalar, CultureInfo.InvariantCulture);
    }

    private static DateTimeOffset? ReadLastActivity(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT MAX(createdAt) FROM token_usage";
        object? value = command.ExecuteScalar();
        if (value is not string text)
        {
            return null;
        }

        return DateTimeOffset.TryParse(
            text,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out DateTimeOffset parsed)
            ? parsed
            : null;
    }

    private static IReadOnlyList<TokenUsageAggregateRow> LoadGroupRows(
        SqliteConnection connection,
        string idColumn,
        string providerColumn,
        int limit)
    {
        string safeId = idColumn == "model" ? "model" : "provider";
        string safeProvider = providerColumn == "provider" ? "provider" : "provider";
        using var command = connection.CreateCommand();
        command.CommandText = $"""
            SELECT {safeId}, {safeProvider}, COALESCE(SUM(cost), 0),
                   COALESCE(SUM(totalTokens), 0), COUNT(DISTINCT sessionId)
            FROM token_usage
            WHERE {safeId} <> ''
            GROUP BY {safeId}, {safeProvider}
            ORDER BY SUM(cost) DESC, SUM(totalTokens) DESC
            LIMIT $limit
            """;
        command.Parameters.AddWithValue("$limit", limit);
        var rows = new List<TokenUsageAggregateRow>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            string id = reader.GetString(0);
            string provider = reader.GetString(1);
            rows.Add(new TokenUsageAggregateRow(
                id,
                DisplayName(id),
                provider,
                reader.GetDouble(2),
                reader.GetInt64(3),
                reader.GetInt32(4)));
        }

        return rows;
    }

    private static string DisplayName(string value) => string.Join(
        " ",
        value.Split(new[] { '-', '_', '.' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Length == 0
                ? part
                : char.ToUpperInvariant(part[0]) + part.Substring(1)));

    private static string FormatTimestamp(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);
}
