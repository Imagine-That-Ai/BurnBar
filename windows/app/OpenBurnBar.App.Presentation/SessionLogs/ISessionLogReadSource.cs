using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.SessionLogs;

/// <summary>
/// The read seam the session-logs view-model consumes. It is the presentation-side
/// mirror of the macOS <c>DataStore</c> reads (<c>fetchConversations</c> +
/// <c>searchConversationsFTS</c>) the SwiftUI view drives, kept dependency-free so the
/// view-model tests can supply an in-memory fake AND the Windows build can bind a
/// real SQLCipher-backed implementation.
///
/// The concrete Windows implementation is <c>StorageSessionLogReadSource</c>
/// (windows/storage/OpenBurnBar.Storage.SessionLogs), which adapts the storage
/// <c>IConversationReadStore</c> (VAL-P0-DB-010). That adapter targets net10.0 like
/// the storage layer; the seam lives here (net8.0) so both the WinUI app and the
/// adapter can share the contract.
/// </summary>
public interface ISessionLogReadSource
{
    /// <summary>List indexed conversations, most-recently-indexed first.
    /// Swift: <c>DataStore.fetchConversations()</c>.</summary>
    Task<IReadOnlyList<SessionLogRecord>> ListAsync(int limit = 200, CancellationToken cancellationToken = default);

    /// <summary>Full-text search returning matched ids in rank order (best first).
    /// Swift: <c>SearchService</c> / <c>ConversationStore.searchConversationsFTS</c>. The
    /// view-model projects these ids over the loaded set, mirroring the Local path's
    /// <c>retrievalMatchedIDs</c> behavior.</summary>
    Task<IReadOnlyList<string>> SearchMatchingIdsAsync(string query, int limit = 200, CancellationToken cancellationToken = default);
}
