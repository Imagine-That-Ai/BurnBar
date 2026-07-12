using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Memories;

// PORTED (record subset) from the FROZEN contract
// OpenBurnBarCore/Sources/OpenBurnBarCore/Memory/MemoryServing.swift.
//
// The Windows memory-review inbox reads exactly these fields off the authority
// record; the full mem0-class contract (add/search/recall/entities/events) is the
// engine's concern and lands with the memory backend port. Keeping this a faithful
// subset lets the inbox view-model + its tests run with zero engine dependency,
// mirroring how the Swift MemoryReviewInboxModel drives against injected closures.

/// <summary>mem0 source kind. Swift: <c>enum MemorySourceKind</c>.</summary>
public enum MemorySourceKind
{
    Chat,
    Code,
}

/// <summary>Memory classification. Swift: <c>enum MemoryKind</c>. Raw string parity
/// (<c>fact</c>/<c>preference</c>/…) is preserved by <see cref="MemoryKindExtensions.RawValue"/>.</summary>
public enum MemoryKind
{
    Fact,
    Preference,
    Event,
    Profile,
    Relationship,
    Other,
}

/// <summary>Quarantine lifecycle state (G4). Swift: <c>enum MemoryReviewStatus</c>.
/// New memories default to <see cref="Quarantined"/> and cannot inject or replicate
/// until approved here.</summary>
public enum MemoryReviewStatus
{
    Quarantined,
    Approved,
    Rejected,
}

/// <summary>Citation lifecycle. Swift: <c>enum MemoryCitationState</c>.</summary>
public enum MemoryCitationState
{
    Live,
    SourcePruned,
    Tombstoned,
}

/// <summary>Lowercase raw-value parity with the Swift <c>String</c>-backed enums,
/// used for kind badges and any wire round-trip.</summary>
public static class MemoryKindExtensions
{
    public static string RawValue(this MemoryKind kind) => kind switch
    {
        MemoryKind.Fact => "fact",
        MemoryKind.Preference => "preference",
        MemoryKind.Event => "event",
        MemoryKind.Profile => "profile",
        MemoryKind.Relationship => "relationship",
        _ => "other",
    };

    public static string RawValue(this MemoryReviewStatus status) => status switch
    {
        MemoryReviewStatus.Quarantined => "quarantined",
        MemoryReviewStatus.Approved => "approved",
        _ => "rejected",
    };
}

/// <summary>mem0-style scope keys. Swift: <c>struct MemoryScope</c>.</summary>
public sealed record MemoryScope(
    string? UserId = null,
    string? AgentId = null,
    string? RunId = null,
    string? AppId = null,
    string? ProjectId = null);

/// <summary>One source citation for a memory. Swift: <c>struct MemoryCitation</c>.</summary>
public sealed record MemoryCitation(
    string Id,
    string ThreadLogicalId,
    string Role,
    DateTimeOffset AuthoredAt,
    string ContentHash,
    string CrossDeviceHmac,
    string? MessageId = null,
    int Occurrence = 0,
    MemoryCitationState CitationState = MemoryCitationState.Live);

/// <summary>
/// The authority record. Swift: <c>struct Memory</c>. <see cref="BodyRedacted"/> is a
/// sealed-snapshot reference (G1) — the fact text is fetched transiently via the
/// inbox's <c>OpenBody</c> seam and is never stored on this record.
/// </summary>
public sealed record Memory(
    string Id,
    MemoryKind Kind,
    MemoryScope Scope,
    double Confidence,
    string BodyRedacted,
    MemoryReviewStatus ReviewStatus,
    IReadOnlyList<MemoryCitation> Citations,
    DateTimeOffset ValidFrom,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    MemorySourceKind SourceKind = MemorySourceKind.Chat,
    DateTimeOffset? ValidTo = null,
    string? SupersededBy = null);

/// <summary>A page request over the memory store. Swift: <c>struct MemoryPageRequest</c>.</summary>
public sealed record MemoryPageRequest(
    MemoryScope Scope,
    int Page = 1,
    int PageSize = 50,
    bool IncludeQuarantined = false);

/// <summary>A page of memories. Swift: <c>struct MemoryPage</c>.</summary>
public sealed record MemoryPage(
    IReadOnlyList<Memory> Items,
    int Page,
    int PageSize,
    int Total);

/// <summary>
/// Optional friendly-message carrier. The Swift model surfaces a
/// <c>LocalizedError.errorDescription</c> when the thrown error provides one, else a
/// generic fallback; a C# exception implementing this interface reproduces that
/// branch (see <c>MemoryReviewInboxModel.FriendlyMessage</c>).
/// </summary>
public interface IFriendlyError
{
    string? FriendlyMessage { get; }
}
