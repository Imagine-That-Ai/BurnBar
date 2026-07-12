using System.Collections.Generic;

namespace OpenBurnBar.Storage;

/// <summary>
/// One row of the encrypted <c>conversations</c> table, projected to the columns
/// the Engine's DataStore seam consumes on the read path. Mirrors the macOS
/// <c>ConversationStore</c> record shape (a subset — the identity + indexed text
/// columns that exist since migration <c>v3_conversations</c>).
/// </summary>
public sealed record ConversationRecord(
    string Id,
    string Provider,
    string SessionId,
    string ProjectName,
    string InferredTaskTitle,
    string FullText,
    string? IndexedAt,
    long MessageCount);

/// <summary>
/// One full-text search hit: the matched <see cref="ConversationRecord"/> plus the
/// SQLCipher/FTS5 <c>bm25()</c> rank and the <c>snippet()</c> markup. Mirrors the
/// macOS <c>SearchResult</c> (conversation + snippet + rank).
/// </summary>
public sealed record ConversationSearchResult(
    ConversationRecord Conversation,
    string Snippet,
    double Rank);

/// <summary>
/// One <c>sqlite_master</c> schema object (table / index / trigger / view),
/// including FTS5 shadow tables. Used for the schema-inventory read and the
/// byte-compat schema hash.
/// </summary>
public sealed record SchemaObject(
    string Type,
    string Name,
    string? Sql);

/// <summary>
/// The observed live SQLCipher parameters read back from the keyed connection —
/// the Windows-side counterpart of
/// <c>openburnbar-db-compat-params-observed.json</c>, used as open-time evidence
/// that the pinned compatibility-4 profile is active.
/// </summary>
public sealed record ObservedCipherParams(
    string CipherVersion,
    string CipherProvider,
    int CipherPageSize,
    int KdfIter,
    string HmacAlgorithm,
    string KdfAlgorithm);

/// <summary>
/// Read-only DataStore seam the Windows Engine calls (via the PAL) to read the
/// shared encrypted database. Deliberately read-only for this un-prune step: it
/// proves the Mac file opens and its content is faithfully reachable. Writes /
/// migrations remain owned by the macOS/daemon side until the write seam lands.
/// </summary>
public interface IConversationReadStore
{
    /// <summary>Count every object in <c>sqlite_master</c> (tables, indexes, triggers, FTS shadows).</summary>
    int CountSchemaObjects();

    /// <summary>List every <c>sqlite_master</c> object ordered by <c>(type, name)</c>.</summary>
    IReadOnlyList<SchemaObject> ListSchemaObjects();

    /// <summary>Fetch a single conversation by primary key, or <c>null</c> if absent / soft-deleted.</summary>
    ConversationRecord? GetConversation(string id);

    /// <summary>List non-deleted conversations, most-recently-indexed first.</summary>
    IReadOnlyList<ConversationRecord> ListConversations(int limit = 50);

    /// <summary>
    /// Full-text search over <c>conversations_fts</c> using an FTS5 <c>MATCH</c>
    /// expression, ranked by <c>bm25()</c> ascending, with <c>snippet()</c> markup.
    /// Mirrors the core query of the macOS <c>ConversationStore.searchConversationsFTS</c>.
    /// </summary>
    IReadOnlyList<ConversationSearchResult> SearchConversationsFts(string match, int limit = 50);
}
