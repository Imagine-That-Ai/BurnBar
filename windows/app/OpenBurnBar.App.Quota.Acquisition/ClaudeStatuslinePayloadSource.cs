using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition;

// ── MECHANISM 1 · acquisition half ───────────────────────────────────────────
//
// Reads the statusline-hook snapshot file the installed wrapper writes
// (ClaudeStatuslineHookInstaller / claude_statusline_bridge.cmd) and turns it
// into a snapshot via the landed portable parser.
//
// Parity sources (macOS):
//   • AgentLens/Services/ProviderQuota/ClaudeQuotaAdapter.swift
//       StatuslinePolicy.maxSnapshotAge (15 min) + isFreshStatuslineSnapshot —
//       freshness is judged by the snapshot FILE's modification instant.
//   • AgentLens/Services/ProviderQuota/ClaudeStatuslineWatcher.swift
//       the change signal that triggers a re-read (the IQuotaFileWatcher seam;
//       the FileSystemWatcher adapter lives in the .Windows sibling).

/// <summary>Statusline snapshot-file source for the Claude Code quota bridge.</summary>
public sealed class ClaudeStatuslinePayloadSource : IQuotaPayloadSource
{
    /// <summary>The coordinator source id (also the watcher routing key).</summary>
    public const string DefaultSourceId = "claude-statusline";

    private readonly string _snapshotPath;
    private readonly IQuotaAcquisitionClock _clock;
    private readonly TimeSpan _maxSnapshotAge;

    /// <summary>Create a source over the snapshot file the bridge wrapper writes.</summary>
    public ClaudeStatuslinePayloadSource(
        string snapshotPath,
        IQuotaAcquisitionClock? clock = null,
        TimeSpan? maxSnapshotAge = null)
    {
        _snapshotPath = snapshotPath ?? throw new ArgumentNullException(nameof(snapshotPath));
        _clock = clock ?? SystemQuotaAcquisitionClock.Instance;
        _maxSnapshotAge = maxSnapshotAge ?? QuotaAcquisitionPolicy.StatuslineMaxSnapshotAge;
    }

    /// <inheritdoc />
    public string SourceId => DefaultSourceId;

    /// <inheritdoc />
    public async Task<ProviderQuotaSnapshot?> TryAcquireAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_snapshotPath))
        {
            return null;
        }

        DateTimeOffset modifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(_snapshotPath), TimeSpan.Zero);
        if (_clock.UtcNow - modifiedAt > _maxSnapshotAge)
        {
            // Swift: a stale statusline snapshot never produces a bucket — the
            // cascade falls through to the other Claude mechanisms.
            return null;
        }

        string json = await File.ReadAllTextAsync(_snapshotPath, cancellationToken).ConfigureAwait(false);
        ProviderQuotaSnapshot snapshot = ClaudeStatuslineQuotaParser.Parse(json, fetchedAt: modifiedAt);
        return snapshot.HasBuckets ? snapshot : null;
    }
}
