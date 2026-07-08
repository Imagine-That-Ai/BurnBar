using System;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Windows write/read seam for <c>switcher_profiles</c> and <c>switcher_active_profile</c>
/// (migration <c>v32_switcher_profiles</c>, <c>v46_drain_target_per_provider</c>).
/// </summary>
public static class SwitcherProfileWriteSeam
{
    public static int UpsertProfile(SqliteConnection connection, SwitcherProfileRow row)
    {
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO switcher_profiles (
                id, targetKind, browserType, browserMetadataJSON,
                cliType, cliMetadataJSON, sortKey, createdAt, updatedAt
            ) VALUES (
                $id, $targetKind, $browserType, $browserMetadataJSON,
                $cliType, $cliMetadataJSON, $sortKey, $createdAt, $updatedAt
            )
            ON CONFLICT(id) DO UPDATE SET
                targetKind = excluded.targetKind,
                browserType = excluded.browserType,
                browserMetadataJSON = excluded.browserMetadataJSON,
                cliType = excluded.cliType,
                cliMetadataJSON = excluded.cliMetadataJSON,
                sortKey = excluded.sortKey,
                updatedAt = excluded.updatedAt
            """;

        command.Parameters.AddWithValue("$id", row.Id);
        command.Parameters.AddWithValue("$targetKind", row.TargetKind);
        command.Parameters.AddWithValue("$browserType", (object?)row.BrowserType ?? DBNull.Value);
        command.Parameters.AddWithValue("$browserMetadataJSON", (object?)row.BrowserMetadataJson ?? DBNull.Value);
        command.Parameters.AddWithValue("$cliType", (object?)row.CliType ?? DBNull.Value);
        command.Parameters.AddWithValue("$cliMetadataJSON", (object?)row.CliMetadataJson ?? DBNull.Value);
        command.Parameters.AddWithValue("$sortKey", row.SortKey);
        command.Parameters.AddWithValue("$createdAt", StorageDateCodec.ToIso(row.CreatedAt));
        command.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToIso(row.UpdatedAt));

        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static int DeleteProfile(SqliteConnection connection, string id)
    {
        using var transaction = connection.BeginTransaction();
        using var deleteProfile = connection.CreateCommand();
        deleteProfile.Transaction = transaction;
        deleteProfile.CommandText = "DELETE FROM switcher_profiles WHERE id = $id";
        deleteProfile.Parameters.AddWithValue("$id", id);
        deleteProfile.ExecuteNonQuery();

        using var clearActive = connection.CreateCommand();
        clearActive.Transaction = transaction;
        clearActive.CommandText =
            """
            UPDATE switcher_active_profile
            SET activeProfileID = NULL, updatedAt = $now
            WHERE activeProfileID = $id
            """;
        clearActive.Parameters.AddWithValue("$id", id);
        clearActive.Parameters.AddWithValue("$now", StorageDateCodec.ToIso(DateTimeOffset.UtcNow));
        clearActive.ExecuteNonQuery();

        transaction.Commit();
        return 1;
    }

    public static void SetGlobalActiveProfile(SqliteConnection connection, string? profileId, DateTimeOffset updatedAt)
    {
        using var transaction = connection.BeginTransaction();
        using var delete = connection.CreateCommand();
        delete.Transaction = transaction;
        delete.CommandText = "DELETE FROM switcher_active_profile WHERE providerID IS NULL";
        delete.ExecuteNonQuery();

        using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText =
            """
            INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt)
            VALUES ($activeProfileID, NULL, $updatedAt)
            """;
        insert.Parameters.AddWithValue("$activeProfileID", (object?)profileId ?? DBNull.Value);
        insert.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToIso(updatedAt));
        insert.ExecuteNonQuery();
        transaction.Commit();
    }

    public static void SetDrainTarget(SqliteConnection connection, string providerKey, string? profileId, DateTimeOffset updatedAt)
    {
        using var transaction = connection.BeginTransaction();
        using var delete = connection.CreateCommand();
        delete.Transaction = transaction;
        delete.CommandText = "DELETE FROM switcher_active_profile WHERE providerID = $providerID";
        delete.Parameters.AddWithValue("$providerID", providerKey);
        delete.ExecuteNonQuery();

        if (profileId is not null)
        {
            using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText =
                """
                INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt)
                VALUES ($activeProfileID, $providerID, $updatedAt)
                """;
            insert.Parameters.AddWithValue("$activeProfileID", profileId);
            insert.Parameters.AddWithValue("$providerID", providerKey);
            insert.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToIso(updatedAt));
            insert.ExecuteNonQuery();
        }

        transaction.Commit();
    }

    public static System.Collections.Generic.List<SwitcherProfileRow> FetchAllProfiles(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM switcher_profiles ORDER BY sortKey ASC, createdAt ASC";
        var list = new System.Collections.Generic.List<SwitcherProfileRow>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            list.Add(ReadProfile(reader));
        }

        return list;
    }

    public static SwitcherActiveStateRow FetchGlobalActiveState(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT activeProfileID, updatedAt FROM switcher_active_profile
            WHERE providerID IS NULL
            ORDER BY activeProfileID IS NOT NULL DESC,
                     COALESCE(updatedAt, '1970-01-01T00:00:00Z') DESC
            LIMIT 1
            """;
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return new SwitcherActiveStateRow(null, DateTimeOffset.UtcNow);
        }

        string? active = reader.IsDBNull(0) ? null : reader.GetString(0);
        DateTimeOffset updated = reader.IsDBNull(1) ? DateTimeOffset.UtcNow : StorageDateCodec.FromIso(reader.GetString(1));
        return new SwitcherActiveStateRow(active, updated);
    }

    public static System.Collections.Generic.Dictionary<string, string> FetchDrainTargets(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT providerID, activeProfileID FROM switcher_active_profile
            WHERE providerID IS NOT NULL AND activeProfileID IS NOT NULL
            """;
        var map = new System.Collections.Generic.Dictionary<string, string>(StringComparer.Ordinal);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            string provider = reader.GetString(0);
            string profile = reader.GetString(1);
            map[provider] = profile;
        }

        return map;
    }

    public static int ReorderProfiles(SqliteConnection connection, System.Collections.Generic.IReadOnlyList<string> idsInOrder, DateTimeOffset updatedAt)
    {
        using var transaction = connection.BeginTransaction();
        for (int i = 0; i < idsInOrder.Count; i++)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                UPDATE switcher_profiles
                SET sortKey = $sortKey, updatedAt = $updatedAt
                WHERE id = $id
                """;
            command.Parameters.AddWithValue("$sortKey", i);
            command.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToIso(updatedAt));
            command.Parameters.AddWithValue("$id", idsInOrder[i]);
            command.ExecuteNonQuery();
        }

        transaction.Commit();
        return idsInOrder.Count;
    }

    public static bool ExistsNormalizedName(SqliteConnection connection, string normalizedName, string? excludingId)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT 1 FROM switcher_profiles
            WHERE (
                LOWER(COALESCE(browserMetadataJSON, cliMetadataJSON)) LIKE $pattern
                OR LOWER(cliMetadataJSON) LIKE $pattern
            )
            AND ($excludingId IS NULL OR id != $excludingId)
            LIMIT 1
            """;
        command.Parameters.AddWithValue("$pattern", "%" + normalizedName + "%");
        command.Parameters.AddWithValue("$excludingId", (object?)excludingId ?? DBNull.Value);
        using var reader = command.ExecuteReader();
        return reader.Read();
    }

    private static SwitcherProfileRow ReadProfile(SqliteDataReader reader)
    {
        return new SwitcherProfileRow(
            Id: reader.GetString(reader.GetOrdinal("id")),
            TargetKind: reader.GetString(reader.GetOrdinal("targetKind")),
            BrowserType: GetStringOrNull(reader, "browserType"),
            BrowserMetadataJson: GetStringOrNull(reader, "browserMetadataJSON"),
            CliType: GetStringOrNull(reader, "cliType"),
            CliMetadataJson: GetStringOrNull(reader, "cliMetadataJSON"),
            SortKey: reader.GetInt32(reader.GetOrdinal("sortKey")),
            CreatedAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "createdAt")),
            UpdatedAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "updatedAt")));
    }

    private static string? GetStringOrNull(SqliteDataReader reader, string column)
    {
        int ord = reader.GetOrdinal(column);
        return reader.IsDBNull(ord) ? null : reader.GetString(ord);
    }
}

public sealed record SwitcherProfileRow(
    string Id,
    string TargetKind,
    string? BrowserType,
    string? BrowserMetadataJson,
    string? CliType,
    string? CliMetadataJson,
    int SortKey,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

public sealed record SwitcherActiveStateRow(string? ActiveProfileId, DateTimeOffset UpdatedAt);