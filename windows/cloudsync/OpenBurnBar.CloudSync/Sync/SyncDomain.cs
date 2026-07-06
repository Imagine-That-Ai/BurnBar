using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Sync;

/// <summary>
/// Executes a domain's collection read against the gateway. Callers build the exact
/// query (filters / order / limit) via the gateway's fluent surface — e.g.
/// <c>g.Collection("users/uid/quota_snapshots").Limit(500).GetDocumentsAsync(ct)</c> —
/// so each domain fully controls its wire shape.
/// </summary>
public delegate Task<ICloudSyncQuerySnapshot> SyncQueryExecutor(ICloudSyncGateway gateway, CancellationToken cancellationToken);

/// <summary>A named live-sync domain: a stable name plus the query that pulls its documents.</summary>
public sealed record SyncDomainDefinition(string Name, SyncQueryExecutor Query)
{
    /// <summary>Build a domain that reads a whole collection with an optional limit.</summary>
    public static SyncDomainDefinition ForCollection(string name, string collectionPath, int? limit = null) =>
        new(name, (gateway, ct) =>
        {
            ICloudSyncCollection collection = gateway.Collection(collectionPath);
            return limit is { } n
                ? collection.Limit(n).GetDocumentsAsync(ct)
                : collection.GetDocumentsAsync(ct);
        });
}

/// <summary>
/// A per-domain change batch raised after a poll cycle diffs the domain's documents
/// against its last-known state. <see cref="FromInitial"/> is true on the domain's
/// first successful poll (every document arrives as <see cref="SyncChangeKind.Added"/>),
/// mirroring a Firestore snapshot-listener's initial delivery.
/// </summary>
public sealed record SyncDomainChangeEvent(
    string Domain,
    IReadOnlyList<SyncDocumentChange> Changes,
    IReadOnlyList<ICloudSyncDocumentSnapshot> Documents,
    bool FromInitial);

/// <summary>
/// A per-domain poll failure. The coordinator does NOT clear the domain's last-known
/// state on error (fail-closed: a failed read never fabricates a "deleted everything"
/// diff); it schedules a backoff retry instead.
/// </summary>
public sealed record SyncDomainErrorEvent(
    string Domain,
    Exception Error,
    int ConsecutiveFailures,
    long RetryDelayMillis,
    long RetryAtMillis);

/// <summary>The outcome of one full <c>PollOnceAsync</c> cycle across all domains.</summary>
public sealed record SyncCycleResult(
    long PolledAtMillis,
    IReadOnlyList<SyncDomainChangeEvent> Changes,
    IReadOnlyList<SyncDomainErrorEvent> Errors)
{
    /// <summary>True when at least one domain failed this cycle (drives the loop's backoff).</summary>
    public bool AnyFailed => Errors.Count > 0;

    /// <summary>The highest consecutive-failure count across the domains that failed this cycle.</summary>
    public int MaxConsecutiveFailures
    {
        get
        {
            int max = 0;
            foreach (SyncDomainErrorEvent error in Errors)
            {
                if (error.ConsecutiveFailures > max) max = error.ConsecutiveFailures;
            }
            return max;
        }
    }
}
