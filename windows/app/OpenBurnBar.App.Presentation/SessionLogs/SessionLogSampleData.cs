using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.SessionLogs;

/// <summary>Fallback when <c>OPENBURNBAR_SQLCIPHER_*</c> is unset (empty list, not demo fiction).</summary>
public static class SessionLogSampleData
{
    public static ISessionLogReadSource CreateReadSource() => EmptyReadSource.Instance;

    private sealed class EmptyReadSource : ISessionLogReadSource
    {
        public static readonly EmptyReadSource Instance = new();

        public Task<IReadOnlyList<SessionLogRecord>> ListAsync(int limit = 200, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult<IReadOnlyList<SessionLogRecord>>(Array.Empty<SessionLogRecord>());
        }

        public Task<IReadOnlyList<string>> SearchMatchingIdsAsync(string query, int limit = 200, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
        }
    }
}