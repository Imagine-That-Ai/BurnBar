using System;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Key/value upsert into <c>app_state</c> (<c>docs/SCHEMA_SQLITE.sql</c>) for string settings such as
/// <c>elderWand.presets.v1</c>.
/// </summary>
public static class ElderWandPresetWriteSeam
{
    public static int UpsertString(SqliteConnection connection, string key, string value, DateTimeOffset updatedAt)
    {
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO app_state (key, value, updatedAt)
            VALUES ($key, $value, $updatedAt)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updatedAt = excluded.updatedAt
            """;
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value);
        command.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToUnixSeconds(updatedAt));
        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static string? ReadString(SqliteConnection connection, string key)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM app_state WHERE key = $key LIMIT 1";
        command.Parameters.AddWithValue("$key", key);
        object? scalar = command.ExecuteScalar();
        return scalar is string s ? s : null;
    }
}