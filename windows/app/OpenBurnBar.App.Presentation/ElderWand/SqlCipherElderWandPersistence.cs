using System;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>
/// SQLCipher-backed <see cref="IElderWandPresetPersistence"/> using <c>app_state</c>
/// (<c>docs/SCHEMA_SQLITE.sql</c>).
/// </summary>
public sealed class SqlCipherElderWandPersistence : IElderWandPresetPersistence, IDisposable
{
    private readonly SqliteConnection _connection;

    public SqlCipherElderWandPersistence(string databasePath, string passphrase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(passphrase);
        _connection = SqlCipherConnection.Open(databasePath, passphrase);
    }

    public void Dispose() => _connection.Dispose();

    public string? ReadString(string key) =>
        ElderWandPresetWriteSeam.ReadString(_connection, key);

    public void WriteString(string key, string value) =>
        ElderWandPresetWriteSeam.UpsertString(_connection, key, value, DateTimeOffset.UtcNow);
}