import Foundation

/// Wave 2.1c-iv: the daemon owns `search_documents`, `search_chunks`, and
/// `search_chunks_fts` (ADR-005) and the Mac app routes its search-index
/// writes through this contract instead of `INSERT`ing into those tables
/// directly. Reads stay on the app's local connection until the read
/// cutover.
///
/// The app finalizes every write set locally — document upserts, chunk
/// diffs (computed against local reads), and replacement sets — and the
/// daemon stores them verbatim inside one transaction per apply. The only
/// fields the daemon assigns are the FTS `rowid` values recorded in
/// `search_chunks.ftsRowid`, exactly as the app's pre-cutover GRDB writes
/// did (FTS row first, `last_insert_rowid()` onto the chunk row).
///
/// Timestamps ride as GRDB text (`yyyy-MM-dd HH:mm:ss.SSS`, UTC) —
/// formatted app-side by the canonical on-disk renderer — and the daemon
/// binds them verbatim, exactly as the app's pre-cutover GRDB writes
/// stored them. The daemon validates the strict GRDB shape and rejects
/// anything else (notably ISO 8601): the columns order lexicographically,
/// so a second timestamp format would silently misorder mixed rows.
///
/// `sourceKind` is a plain string, not an enum, for the same reason as the
/// vector-snapshot lane: an unknown future spelling must fail validation
/// loudly (`invalidParams`) instead of crashing a failable enum decode
/// inside the RPC envelope, and the daemon must never reinterpret the
/// value — the app's `SearchSourceKind` raw values are stored verbatim.
public struct BurnBarSearchIndexDocumentRow: Codable, Equatable, Sendable {
    public let id: String
    public let sourceKind: String
    public let sourceID: String
    public let sourceVersionID: String
    public let provider: String?
    public let projectName: String?
    public let title: String
    public let subtitle: String?
    public let bodyPreview: String?
    public let sourceUpdatedAtText: String?
    public let indexedAtText: String
    public let contentHash: String?
    public let createdAtText: String
    public let updatedAtText: String

    public init(
        id: String,
        sourceKind: String,
        sourceID: String,
        sourceVersionID: String,
        provider: String? = nil,
        projectName: String? = nil,
        title: String,
        subtitle: String? = nil,
        bodyPreview: String? = nil,
        sourceUpdatedAtText: String? = nil,
        indexedAtText: String,
        contentHash: String? = nil,
        createdAtText: String,
        updatedAtText: String
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceVersionID = sourceVersionID
        self.provider = provider
        self.projectName = projectName
        self.title = title
        self.subtitle = subtitle
        self.bodyPreview = bodyPreview
        self.sourceUpdatedAtText = sourceUpdatedAtText
        self.indexedAtText = indexedAtText
        self.contentHash = contentHash
        self.createdAtText = createdAtText
        self.updatedAtText = updatedAtText
    }
}

/// One chunk row the app finalized. Carries no `ftsRowid`: that mapping is
/// daemon-assigned at insert time. The FTS row's `title`/`projectName`/
/// `provider` ride once per mutation batch on
/// `BurnBarSearchIndexChunkMutations`, not per chunk — the app supplies that
/// context explicitly from the finalized document in hand (it cannot read
/// the document row back: the daemon owns `search_documents`).
public struct BurnBarSearchIndexChunkRow: Codable, Equatable, Sendable {
    public let id: String
    public let documentID: String
    public let sourceKind: String
    public let sourceID: String
    public let sourceVersionID: String
    public let ordinal: Int
    public let startOffset: Int
    public let endOffset: Int
    public let messageStartOffset: Int?
    public let messageEndOffset: Int?
    public let sectionPath: String?
    public let text: String
    public let contentHash: String?
    public let createdAtText: String
    public let updatedAtText: String

    public init(
        id: String,
        documentID: String,
        sourceKind: String,
        sourceID: String,
        sourceVersionID: String = "",
        ordinal: Int,
        startOffset: Int,
        endOffset: Int,
        messageStartOffset: Int? = nil,
        messageEndOffset: Int? = nil,
        sectionPath: String? = nil,
        text: String,
        contentHash: String? = nil,
        createdAtText: String,
        updatedAtText: String
    ) {
        self.id = id
        self.documentID = documentID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceVersionID = sourceVersionID
        self.ordinal = ordinal
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.messageStartOffset = messageStartOffset
        self.messageEndOffset = messageEndOffset
        self.sectionPath = sectionPath
        self.text = text
        self.contentHash = contentHash
        self.createdAtText = createdAtText
        self.updatedAtText = updatedAtText
    }
}

/// Deletes every document (and its chunks, via the same FTS-cleaning
/// deletes the app's pre-cutover path ran) for one `sourceKind`/`sourceID`
/// pair.
public struct BurnBarSearchIndexDeleteDocuments: Codable, Equatable, Sendable {
    public let sourceKind: String
    public let sourceID: String

    public init(sourceKind: String, sourceID: String) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
    }
}

/// One finalized chunk batch for a single document: the chunk IDs to
/// delete plus the chunk rows to insert, with the FTS context the daemon
/// stamps on the new FTS rows. The app keeps its 64-row batching and
/// inter-batch pauses and sends one apply per batch, so wire messages stay
/// small and daemon write transactions stay short.
public struct BurnBarSearchIndexChunkMutations: Codable, Equatable, Sendable {
    public let documentID: String
    public let ftsTitle: String
    public let ftsProjectName: String
    public let ftsProvider: String
    public let chunkIDsToDelete: [String]
    public let chunksToInsert: [BurnBarSearchIndexChunkRow]

    public init(
        documentID: String,
        ftsTitle: String,
        ftsProjectName: String,
        ftsProvider: String,
        chunkIDsToDelete: [String] = [],
        chunksToInsert: [BurnBarSearchIndexChunkRow] = []
    ) {
        self.documentID = documentID
        self.ftsTitle = ftsTitle
        self.ftsProjectName = ftsProjectName
        self.ftsProvider = ftsProvider
        self.chunkIDsToDelete = chunkIDsToDelete
        self.chunksToInsert = chunksToInsert
    }
}

/// One atomic search-index apply. At least one operation must be present;
/// a fully empty apply is a caller bug (`invalidParams`). The daemon
/// applies document deletes first, then the document upsert, then chunk
/// mutations (deletes before inserts) — the order is fixed and documented
/// because the app never combines operation kinds in one call today, and
/// any future combined caller must be able to reason about it.
public struct BurnBarSearchIndexApplyRequest: Codable, Equatable, Sendable {
    public let documentUpsert: BurnBarSearchIndexDocumentRow?
    public let documentDelete: BurnBarSearchIndexDeleteDocuments?
    public let chunkMutations: BurnBarSearchIndexChunkMutations?

    public init(
        documentUpsert: BurnBarSearchIndexDocumentRow? = nil,
        documentDelete: BurnBarSearchIndexDeleteDocuments? = nil,
        chunkMutations: BurnBarSearchIndexChunkMutations? = nil
    ) {
        self.documentUpsert = documentUpsert
        self.documentDelete = documentDelete
        self.chunkMutations = chunkMutations
    }
}

public struct BurnBarSearchIndexApplyResponse: Codable, Equatable, Sendable {
    public let documentsUpserted: Int
    public let documentsDeleted: Int
    public let chunksAdded: Int
    public let chunksDeleted: Int

    public init(documentsUpserted: Int, documentsDeleted: Int, chunksAdded: Int, chunksDeleted: Int) {
        self.documentsUpserted = documentsUpserted
        self.documentsDeleted = documentsDeleted
        self.chunksAdded = chunksAdded
        self.chunksDeleted = chunksDeleted
    }
}
