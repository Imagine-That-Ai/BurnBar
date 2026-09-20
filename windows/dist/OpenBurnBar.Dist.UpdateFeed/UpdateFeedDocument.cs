// The direct-download update feed document (Phase 5 · signed distribution).
//
// Pure record (System only). This is the Windows analog of the appcast.xml / latest-macos.json
// the release pipeline publishes. It carries a schema version (so an old client can reject a feed
// it does not understand) and a list of per-platform/per-channel signed entries.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>A parsed update feed: schema envelope plus the signed release entries.</summary>
public sealed record UpdateFeedDocument
{
    /// <summary>The schema version this library understands.</summary>
    public const int CurrentSchemaVersion = 1;

    /// <summary>Feed identifier — always "openburnbar-windows" for this channel.</summary>
    public const string FeedId = "openburnbar-windows";

    /// <summary>Declared schema version of the parsed feed.</summary>
    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    /// <summary>Feed identifier string.</summary>
    public string Feed { get; init; } = FeedId;

    /// <summary>When the feed was generated (UTC).</summary>
    public DateTimeOffset GeneratedAtUtc { get; init; }

    /// <summary>The release entries.</summary>
    public IReadOnlyList<UpdateFeedEntry> Entries { get; init; } = Array.Empty<UpdateFeedEntry>();
}
