using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Presentation.SessionLogs;

/// <summary>
/// Owns a read-only <see cref="OpenBurnBarStorage"/> for the lifetime of the session-logs surface.
/// </summary>
public sealed class SqlCipherSessionLogReadSource : ISessionLogReadSource, IDisposable
{
    private readonly OpenBurnBarStorage _storage;
    private readonly StorageSessionLogReadSource _inner;

    public SqlCipherSessionLogReadSource(string databasePath, string passphrase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(passphrase);
        _storage = OpenBurnBarStorage.OpenReadOnly(databasePath, passphrase);
        _inner = new StorageSessionLogReadSource(_storage);
    }

    public Task<IReadOnlyList<SessionLogRecord>> ListAsync(int limit = 200, CancellationToken cancellationToken = default) =>
        _inner.ListAsync(limit, cancellationToken);

    public Task<IReadOnlyList<string>> SearchMatchingIdsAsync(string query, int limit = 200, CancellationToken cancellationToken = default) =>
        _inner.SearchMatchingIdsAsync(query, limit, cancellationToken);

    public void Dispose() => _storage.Dispose();
}