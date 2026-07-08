using System;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Windows write/read seam for <c>budget_rules</c> and <c>budget_events</c> — peer of Mac
/// <c>BudgetRulesStore</c> (migration <c>v42_budget_rules_and_events</c>).
/// </summary>
public static class BudgetRuleWriteSeam
{
    public static int UpsertRule(SqliteConnection connection, BudgetRuleRow row)
    {
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO budget_rules (
                id, scope, identifier, providerID, accountID, projectName, label,
                amountUSD, period, behavior, fallbackCredentialIDsJSON, pausedUntil,
                createdAt, updatedAt, syncedAt, sourceDeviceID, isEnabled
            ) VALUES (
                $id, $scope, $identifier, $providerID, $accountID, $projectName, $label,
                $amountUSD, $period, $behavior, $fallbackJSON, $pausedUntil,
                $createdAt, $updatedAt, $syncedAt, $sourceDeviceID, $isEnabled
            )
            ON CONFLICT(id) DO UPDATE SET
                scope = excluded.scope,
                identifier = excluded.identifier,
                providerID = excluded.providerID,
                accountID = excluded.accountID,
                projectName = excluded.projectName,
                label = excluded.label,
                amountUSD = excluded.amountUSD,
                period = excluded.period,
                behavior = excluded.behavior,
                fallbackCredentialIDsJSON = excluded.fallbackCredentialIDsJSON,
                pausedUntil = excluded.pausedUntil,
                updatedAt = excluded.updatedAt,
                syncedAt = NULL,
                isEnabled = excluded.isEnabled
            """;

        BindRule(command, row);
        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static int DeleteRule(SqliteConnection connection, string id)
    {
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM budget_rules WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static int InsertEvent(SqliteConnection connection, BudgetEventRow row)
    {
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO budget_events (
                id, ruleID, kind, source, amountAtEvent, limitAtEvent,
                detailJSON, occurredAt, syncedAt, sourceDeviceID
            ) VALUES (
                $id, $ruleID, $kind, $source, $amountAtEvent, $limitAtEvent,
                $detailJSON, $occurredAt, $syncedAt, $sourceDeviceID
            )
            """;

        command.Parameters.AddWithValue("$id", row.Id);
        command.Parameters.AddWithValue("$ruleID", row.RuleId);
        command.Parameters.AddWithValue("$kind", row.Kind);
        command.Parameters.AddWithValue("$source", (object?)row.Source ?? DBNull.Value);
        command.Parameters.AddWithValue("$amountAtEvent", row.AmountAtEvent);
        command.Parameters.AddWithValue("$limitAtEvent", row.LimitAtEvent);
        command.Parameters.AddWithValue("$detailJSON", (object?)row.DetailJson ?? DBNull.Value);
        command.Parameters.AddWithValue("$occurredAt", StorageDateCodec.ToIso(row.OccurredAt));
        command.Parameters.AddWithValue("$syncedAt", row.SyncedAt is DateTimeOffset synced ? StorageDateCodec.ToIso(synced) : DBNull.Value);
        command.Parameters.AddWithValue("$sourceDeviceID", (object?)row.SourceDeviceId ?? DBNull.Value);

        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static System.Collections.Generic.List<BudgetRuleRow> FetchAllRules(SqliteConnection connection, bool includeDisabled)
    {
        using var command = connection.CreateCommand();
        command.CommandText = includeDisabled
            ? "SELECT * FROM budget_rules ORDER BY createdAt DESC"
            : "SELECT * FROM budget_rules WHERE isEnabled = 1 ORDER BY createdAt DESC";
        return ReadAllRules(command);
    }

    public static System.Collections.Generic.List<BudgetEventRow> FetchRecentEvents(SqliteConnection connection, int limit)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM budget_events ORDER BY occurredAt DESC LIMIT $limit";
        command.Parameters.AddWithValue("$limit", Math.Max(0, limit));
        var list = new System.Collections.Generic.List<BudgetEventRow>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            if (TryReadEvent(reader, out var row))
            {
                list.Add(row);
            }
        }

        return list;
    }

    private static void BindRule(SqliteCommand command, BudgetRuleRow row)
    {
        string? fallbackJson = null;
        if (row.FallbackCredentialIds is { Count: > 0 })
        {
            fallbackJson = JsonSerializer.Serialize(row.FallbackCredentialIds);
        }

        command.Parameters.AddWithValue("$id", row.Id);
        command.Parameters.AddWithValue("$scope", row.Scope);
        command.Parameters.AddWithValue("$identifier", (object?)row.Identifier ?? DBNull.Value);
        command.Parameters.AddWithValue("$providerID", (object?)row.ProviderId ?? DBNull.Value);
        command.Parameters.AddWithValue("$accountID", (object?)row.AccountId ?? DBNull.Value);
        command.Parameters.AddWithValue("$projectName", (object?)row.ProjectName ?? DBNull.Value);
        command.Parameters.AddWithValue("$label", (object?)row.Label ?? DBNull.Value);
        command.Parameters.AddWithValue("$amountUSD", row.AmountUsd);
        command.Parameters.AddWithValue("$period", row.Period);
        command.Parameters.AddWithValue("$behavior", row.Behavior);
        command.Parameters.AddWithValue("$fallbackJSON", (object?)fallbackJson ?? DBNull.Value);
        command.Parameters.AddWithValue("$pausedUntil", row.PausedUntil is DateTimeOffset paused ? StorageDateCodec.ToIso(paused) : DBNull.Value);
        command.Parameters.AddWithValue("$createdAt", StorageDateCodec.ToIso(row.CreatedAt));
        command.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToIso(row.UpdatedAt));
        command.Parameters.AddWithValue("$syncedAt", row.SyncedAt is DateTimeOffset synced ? StorageDateCodec.ToIso(synced) : DBNull.Value);
        command.Parameters.AddWithValue("$sourceDeviceID", (object?)row.SourceDeviceId ?? DBNull.Value);
        command.Parameters.AddWithValue("$isEnabled", row.IsEnabled ? 1 : 0);
    }

    private static System.Collections.Generic.List<BudgetRuleRow> ReadAllRules(SqliteCommand command)
    {
        var list = new System.Collections.Generic.List<BudgetRuleRow>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            if (TryReadRule(reader, out var row))
            {
                list.Add(row);
            }
        }

        return list;
    }

    private static bool TryReadRule(SqliteDataReader reader, out BudgetRuleRow row)
    {
        row = default!;
        string id = reader.GetString(reader.GetOrdinal("id"));
        string scope = reader.GetString(reader.GetOrdinal("scope"));
        string period = reader.GetString(reader.GetOrdinal("period"));
        string behavior = reader.GetString(reader.GetOrdinal("behavior"));
        double amount = reader.GetDouble(reader.GetOrdinal("amountUSD"));
        int enabled = reader.GetInt32(reader.GetOrdinal("isEnabled"));

        var fallbacks = System.Array.Empty<string>();
        int fallbackOrd = reader.GetOrdinal("fallbackCredentialIDsJSON");
        if (!reader.IsDBNull(fallbackOrd))
        {
            string? json = reader.GetString(fallbackOrd);
            if (!string.IsNullOrEmpty(json))
            {
                fallbacks = JsonSerializer.Deserialize<string[]>(json) ?? System.Array.Empty<string>();
            }
        }

        row = new BudgetRuleRow(
            Id: id,
            Scope: scope,
            Identifier: GetStringOrNull(reader, "identifier"),
            ProviderId: GetStringOrNull(reader, "providerID"),
            AccountId: GetStringOrNull(reader, "accountID"),
            ProjectName: GetStringOrNull(reader, "projectName"),
            Label: GetStringOrNull(reader, "label"),
            AmountUsd: amount,
            Period: period,
            Behavior: behavior,
            FallbackCredentialIds: fallbacks,
            PausedUntil: GetDateOrNull(reader, "pausedUntil"),
            CreatedAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "createdAt")),
            UpdatedAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "updatedAt")),
            SyncedAt: GetDateOrNull(reader, "syncedAt"),
            SourceDeviceId: GetStringOrNull(reader, "sourceDeviceID"),
            IsEnabled: enabled != 0);

        return true;
    }

    private static bool TryReadEvent(SqliteDataReader reader, out BudgetEventRow row)
    {
        row = new BudgetEventRow(
            Id: reader.GetString(reader.GetOrdinal("id")),
            RuleId: reader.GetString(reader.GetOrdinal("ruleID")),
            Kind: reader.GetString(reader.GetOrdinal("kind")),
            Source: GetStringOrNull(reader, "source"),
            AmountAtEvent: reader.GetDouble(reader.GetOrdinal("amountAtEvent")),
            LimitAtEvent: reader.GetDouble(reader.GetOrdinal("limitAtEvent")),
            DetailJson: GetStringOrNull(reader, "detailJSON"),
            OccurredAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "occurredAt")),
            SyncedAt: GetDateOrNull(reader, "syncedAt"),
            SourceDeviceId: GetStringOrNull(reader, "sourceDeviceID"));

        return true;
    }

    private static string? GetStringOrNull(SqliteDataReader reader, string column)
    {
        int ord = reader.GetOrdinal(column);
        return reader.IsDBNull(ord) ? null : reader.GetString(ord);
    }

    private static DateTimeOffset? GetDateOrNull(SqliteDataReader reader, string column)
    {
        string? text = GetStringOrNull(reader, column);
        return string.IsNullOrWhiteSpace(text) ? null : StorageDateCodec.FromIso(text);
    }
}

public sealed record BudgetRuleRow(
    string Id,
    string Scope,
    string? Identifier,
    string? ProviderId,
    string? AccountId,
    string? ProjectName,
    string? Label,
    double AmountUsd,
    string Period,
    string Behavior,
    System.Collections.Generic.IReadOnlyList<string> FallbackCredentialIds,
    DateTimeOffset? PausedUntil,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? SyncedAt,
    string? SourceDeviceId,
    bool IsEnabled);

public sealed record BudgetEventRow(
    string Id,
    string RuleId,
    string Kind,
    string? Source,
    double AmountAtEvent,
    double LimitAtEvent,
    string? DetailJson,
    DateTimeOffset OccurredAt,
    DateTimeOffset? SyncedAt,
    string? SourceDeviceId);