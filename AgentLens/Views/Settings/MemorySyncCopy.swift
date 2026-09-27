import Foundation

/// The one place memory sync lives.
///
/// Before this pane, every memory-sync control sat inside the *Indexing &
/// Search* page under the General tab — three levels below a row whose subtitle
/// read "Local index, embeddings, cross-encoder reranking". A member looking for
/// sync opened **Devices & Sync**, found a section literally headed "Sync"
/// holding exactly one row (Cloud sync), and concluded memory sync did not
/// exist. It did; it was just filed under the wrong noun.
///
/// So the controls moved here, and this pane is now the single implementation.
/// Both entry points — Devices & Sync → Sync → "Memory Sync" and Search &
/// Memory → Memory → "Memory Sync" — push *this* view, rather than rendering a
/// second copy that could drift from it.
enum MemorySyncCopy {

    /// The pane's own title, and the label of both rows that lead to it. One
    /// constant so the row a member clicks and the screen they land on can
    /// never disagree.
    static let title = "Memory Sync"

    /// The row subtitle in both entry points. Names both halves, because both
    /// halves ship: the push (backup) landed in Memory Blind Sync PR 1, and the
    /// pull plus the engine merge landed in PR 2 (#2519).
    static let rowSubtitle =
        "Back up approved memories, and pull them back down onto your other signed-in devices"

    /// The honest one-liner at the top of the pane.
    ///
    /// Every clause is a claim this repo can back:
    ///   * "sealed on this Mac" — `CloudVaultCrypto` seals `sealedMemory` with a
    ///     Keychain-held key; `firestore.rules`' `validMemoryFactKeys()` rejects
    ///     a document carrying `text`, `body`, `citations`, or any vector.
    ///   * "approved" — the rules require `reviewStatus == "approved"`; nothing
    ///     awaiting review can be written at all.
    ///   * "arrive on your other signed-in devices" — the pull half and the
    ///     engine merge are on `main` (`MemoryCloudPullService`,
    ///     `daemon.memory.sync.inbox.list` / `.ack`), so this is a statement
    ///     about today rather than a roadmap.
    static let summary =
        "Off by default. Memories you have approved are sealed on this Mac before they leave it, "
        + "and — with both switches on — arrive on your other signed-in devices and merge into "
        + "their memory. BurnBar holds no key and cannot read any of it."

    /// The boundary that surprises people, stated where they will meet it.
    /// A project's identity is derived from its git origin and root commit; a
    /// non-git folder falls back to a local path fingerprint, which differs on
    /// every machine, so its memories travel but never converge.
    static let gitBoundaryNote =
        "Memories learned in a git repository merge across your devices, because a repo has the "
        + "same identity everywhere. Memories from a folder that is not a git repository still "
        + "travel and still arrive — they simply land as separate entries, because that folder "
        + "has no identity your other Mac can recognise."
}
