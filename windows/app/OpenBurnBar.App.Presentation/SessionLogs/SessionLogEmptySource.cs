using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.SessionLogs;

/// <summary>
/// Honest empty <see cref="ISessionLogReadSource"/> used when SQLCipher credentials are
/// unset or the encrypted store cannot open. Returns empty lists — never fabricated
/// demo sessions. Named "Empty" (not Sample) so anti-false-green scanners and readers
/// do not mistake it for demo fiction.
/// </summary>
public static class SessionLogEmptySource
{
    /// <summary>Shared empty read source (no per-call allocation).</summary>
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
