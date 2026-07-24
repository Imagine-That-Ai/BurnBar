using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// The Windows WRITE path into the shared encrypted database — the peer of the
/// Mac <c>UsageStore.upsertUsage</c>. Writes a <c>token_usage</c> row inside a
/// transaction, using the same column set and the same natural-key
/// <c>ON CONFLICT</c> upsert as production, so a Windows write and a Mac write are
/// interchangeable against the same file.
/// </summary>
public static class TokenUsageWriteSeam
{
    /// <summary>
    /// Insert (or idempotently upsert) <paramref name="record"/> inside a
    /// transaction and return the number of affected rows. The transaction commits
    /// atomically; on any error it rolls back and the file is left untouched.
    /// </summary>
    /// <remarks>
    /// The <c>ON CONFLICT</c> target
    /// <c>(provider, sessionId, model, COALESCE(sourceDeviceId,''), COALESCE(providerAccountID,''))</c>
    /// is the production unique index (<c>token_usage_unique_session_model_idx</c>
    /// and its successors). Exercising it proves the Mac-authored constraint is
    /// present and honored on the Windows write path.
    /// </remarks>
    public static int WriteTokenUsage(SqliteConnection connection, TokenUsageRecord record)
    {
        using var transaction = connection.BeginTransaction();
        int affected = WriteTokenUsage(connection, transaction, record);
        transaction.Commit();
        return affected;
    }

    /// <summary>Compatibility entry point for existing scan callers.</summary>
    public static int WriteTokenUsages(
        SqliteConnection connection,
        IReadOnlyList<TokenUsageRecord> records) =>
        WriteTokenUsageBatch(connection, records);

    /// <summary>
    /// Atomically upsert a complete parser scan without opening one transaction
    /// per row. An exception rolls back every row in the batch.
    /// </summary>
    public static int WriteTokenUsageBatch(
        SqliteConnection connection,
        IEnumerable<TokenUsageRecord> records)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(records);

        using var transaction = connection.BeginTransaction();
        int affected = WriteTokenUsageBatch(connection, transaction, records);
        transaction.Commit();
        return affected;
    }

    internal static int WriteTokenUsageBatch(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IEnumerable<TokenUsageRecord> records)
    {
        int affected = 0;
        foreach (TokenUsageRecord record in records)
        {
            affected += WriteTokenUsage(connection, transaction, record);
        }
        return affected;
    }

    private static int WriteTokenUsage(
        SqliteConnection connection,
        SqliteTransaction transaction,
        TokenUsageRecord record)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO token_usage (
                id, provider, sessionId, projectName, model,
                inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                usageSource, executionSourceID, executionSourceName,
                executionSourceKind, executionSourceConfidence,
                sourceDeviceId, sourceDeviceName, isRemote,
                providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                provenanceMethod, provenanceConfidence, estimatorVersion, parentRequestID
            ) VALUES (
                $id, $provider, $sessionId, $projectName, $model,
                $inputTokens, $outputTokens, $cacheCreationTokens, $cacheReadTokens,
                $reasoningTokens, $totalTokens, $cost, $startTime, $endTime, $createdAt,
                $usageSource, $executionSourceID, $executionSourceName,
                $executionSourceKind, $executionSourceConfidence,
                $sourceDeviceId, $sourceDeviceName, $isRemote,
                $providerID, $providerAccountID, $providerAccountLabel, $providerAccountSource,
                $provenanceMethod, $provenanceConfidence, $estimatorVersion, $parentRequestID
            )
            ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, '')) DO UPDATE SET
                projectName = excluded.projectName,
                inputTokens = excluded.inputTokens,
                outputTokens = excluded.outputTokens,
                cacheCreationTokens = excluded.cacheCreationTokens,
                cacheReadTokens = excluded.cacheReadTokens,
                reasoningTokens = excluded.reasoningTokens,
                totalTokens = excluded.totalTokens,
                cost = excluded.cost,
                startTime = excluded.startTime,
                endTime = excluded.endTime,
                createdAt = excluded.createdAt,
                executionSourceID = CASE
                    WHEN excluded.executionSourceID != 'unknown' AND
                        CASE excluded.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        >=
                        CASE token_usage.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                    THEN excluded.executionSourceID ELSE token_usage.executionSourceID END,
                executionSourceName = CASE
                    WHEN excluded.executionSourceID != 'unknown' AND
                        CASE excluded.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        >=
                        CASE token_usage.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                    THEN excluded.executionSourceName ELSE token_usage.executionSourceName END,
                executionSourceKind = CASE
                    WHEN excluded.executionSourceID != 'unknown' AND
                        CASE excluded.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        >=
                        CASE token_usage.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                    THEN excluded.executionSourceKind ELSE token_usage.executionSourceKind END,
                executionSourceConfidence = CASE
                    WHEN excluded.executionSourceID != 'unknown' AND
                        CASE excluded.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        >=
                        CASE token_usage.executionSourceConfidence
                            WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                    THEN excluded.executionSourceConfidence ELSE token_usage.executionSourceConfidence END
            """;

        Bind(command, "$id", record.Id);
        Bind(command, "$provider", record.Provider);
        Bind(command, "$sessionId", record.SessionId);
        Bind(command, "$projectName", record.ProjectName);
        Bind(command, "$model", record.Model);
        Bind(command, "$inputTokens", record.InputTokens);
        Bind(command, "$outputTokens", record.OutputTokens);
        Bind(command, "$cacheCreationTokens", record.CacheCreationTokens);
        Bind(command, "$cacheReadTokens", record.CacheReadTokens);
        Bind(command, "$reasoningTokens", record.ReasoningTokens);
        Bind(command, "$totalTokens", record.TotalTokens);
        Bind(command, "$cost", record.Cost);
        Bind(command, "$startTime", record.StartTime);
        Bind(command, "$endTime", record.EndTime);
        Bind(command, "$createdAt", record.CreatedAt);
        Bind(command, "$usageSource", record.UsageSource);
        Bind(command, "$executionSourceID", record.ExecutionSourceID);
        Bind(command, "$executionSourceName", record.ExecutionSourceName);
        Bind(command, "$executionSourceKind", record.ExecutionSourceKind);
        Bind(command, "$executionSourceConfidence", record.ExecutionSourceConfidence);
        Bind(command, "$sourceDeviceId", (object?)record.SourceDeviceId ?? DBNull.Value);
        Bind(command, "$sourceDeviceName", (object?)record.SourceDeviceName ?? DBNull.Value);
        Bind(command, "$isRemote", record.IsRemote ? 1 : 0);
        Bind(command, "$providerID", (object?)record.ProviderID ?? DBNull.Value);
        Bind(command, "$providerAccountID", (object?)record.ProviderAccountID ?? DBNull.Value);
        Bind(command, "$providerAccountLabel", (object?)record.ProviderAccountLabel ?? DBNull.Value);
        Bind(command, "$providerAccountSource", (object?)record.ProviderAccountSource ?? DBNull.Value);
        Bind(command, "$provenanceMethod", record.ProvenanceMethod);
        Bind(command, "$provenanceConfidence", record.ProvenanceConfidence);
        Bind(command, "$estimatorVersion", record.EstimatorVersion);
        Bind(command, "$parentRequestID", (object?)record.ParentRequestID ?? DBNull.Value);

        return command.ExecuteNonQuery();
    }

    /// <summary>
    /// Read a single <c>token_usage</c> row back by primary key, or <c>null</c> if
    /// absent. Used to prove round-trip integrity after a reopen.
    /// </summary>
    public static TokenUsageRecord? ReadTokenUsage(SqliteConnection connection, string id)
    {
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
            FROM token_usage WHERE id = $id
            """;
        Bind(command, "$id", id);

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

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
            UsageSource = reader.GetString(15),
            ExecutionSourceID = reader.GetString(16),
            ExecutionSourceName = reader.GetString(17),
            ExecutionSourceKind = reader.GetString(18),
            ExecutionSourceConfidence = reader.GetString(19),
            SourceDeviceId = reader.IsDBNull(20) ? null : reader.GetString(20),
            SourceDeviceName = reader.IsDBNull(21) ? null : reader.GetString(21),
            IsRemote = reader.GetInt64(22) != 0,
            ProviderID = reader.IsDBNull(23) ? null : reader.GetString(23),
            ProviderAccountID = reader.IsDBNull(24) ? null : reader.GetString(24),
            ProviderAccountLabel = reader.IsDBNull(25) ? null : reader.GetString(25),
            ProviderAccountSource = reader.IsDBNull(26) ? null : reader.GetString(26),
            ProvenanceMethod = reader.GetString(27),
            ProvenanceConfidence = reader.GetString(28),
            EstimatorVersion = reader.GetString(29),
            ParentRequestID = reader.IsDBNull(30) ? null : reader.GetString(30),
        };
    }

    private static void Bind(SqliteCommand command, string name, object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }
}
