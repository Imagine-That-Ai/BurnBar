using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Sync;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// The live Firestore sync orchestration: poll-then-snapshot-diff, per-domain change
/// events, fail-closed state retention + backoff, the RunAsync loop cadence, and the
/// real-gateway path driven by a RecordingTransport replaying Firestore runQuery
/// responses across polls.
/// </summary>
public sealed class FirestoreSyncCoordinatorTests
{
    private const string QuotaPath = "users/u/quota_snapshots";
    private const string DomainName = "quota_snapshots";

    private static CloudSyncFields Fields(params (string Key, CloudSyncValue Value)[] pairs) =>
        CloudSyncFields.From(pairs.Select(p => new KeyValuePair<string, CloudSyncValue>(p.Key, p.Value)));

    private static SyncDomainDefinition[] QuotaDomain() =>
        new[] { SyncDomainDefinition.ForCollection(DomainName, QuotaPath, limit: 500) };

    // ── FakeGateway-driven diff semantics ────────────────────────────────────
    [Fact]
    public async Task Initial_poll_delivers_all_docs_as_added_from_initial()
    {
        var gateway = new FakeCloudSyncGateway();
        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(1))), $"{QuotaPath}/d1");
        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(2))), $"{QuotaPath}/d2");

        var coordinator = new FirestoreSyncCoordinator(gateway, QuotaDomain(), new MutableSyncClock(1000));
        var events = new List<SyncDomainChangeEvent>();
        coordinator.DomainChanged += events.Add;

        SyncCycleResult result = await coordinator.PollOnceAsync();

        SyncDomainChangeEvent evt = Assert.Single(events);
        Assert.True(evt.FromInitial);
        Assert.Equal(DomainName, evt.Domain);
        Assert.Equal(2, evt.Changes.Count);
        Assert.All(evt.Changes, c => Assert.Equal(SyncChangeKind.Added, c.Kind));
        Assert.False(result.AnyFailed);
        Assert.Equal(2, coordinator.LastKnownState(DomainName).Count);
    }

    [Fact]
    public async Task Second_poll_delivers_modified_and_dedupes_unchanged()
    {
        var gateway = new FakeCloudSyncGateway();
        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(1))), $"{QuotaPath}/d1");
        var coordinator = new FirestoreSyncCoordinator(gateway, QuotaDomain(), new MutableSyncClock(1000));
        var events = new List<SyncDomainChangeEvent>();
        coordinator.DomainChanged += events.Add;

        await coordinator.PollOnceAsync();               // initial
        await coordinator.PollOnceAsync();               // no change → no event
        Assert.Single(events);

        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(9))), $"{QuotaPath}/d1"); // modify
        await coordinator.PollOnceAsync();

        Assert.Equal(2, events.Count);
        SyncDocumentChange change = Assert.Single(events[1].Changes);
        Assert.Equal(SyncChangeKind.Modified, change.Kind);
        Assert.Equal(9, ((CloudSyncValue.IntegerValue)change.Data["n"]!).Value);
        Assert.False(events[1].FromInitial);
    }

    [Fact]
    public async Task Removed_document_is_diffed_as_removed()
    {
        var gateway = new FakeCloudSyncGateway();
        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(1))), $"{QuotaPath}/d1");
        var coordinator = new FirestoreSyncCoordinator(gateway, QuotaDomain(), new MutableSyncClock(1000));
        var events = new List<SyncDomainChangeEvent>();
        coordinator.DomainChanged += events.Add;

        await coordinator.PollOnceAsync();                                  // initial (d1 added)
        await gateway.Collection(QuotaPath).Document("d1").DeleteDocumentAsync();
        await coordinator.PollOnceAsync();

        SyncDocumentChange change = Assert.Single(events[1].Changes);
        Assert.Equal(SyncChangeKind.Removed, change.Kind);
        Assert.Equal("d1", change.DocumentId);
        Assert.Empty(coordinator.LastKnownState(DomainName));
    }

    // ── Fail-closed + backoff ────────────────────────────────────────────────
    [Fact]
    public async Task Failed_poll_preserves_state_raises_error_and_recovers()
    {
        var gateway = new FakeCloudSyncGateway();
        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(1))), $"{QuotaPath}/d1");
        var backoff = new SyncBackoffPolicy(baseDelayMillis: 1_000, maxDelayMillis: 60_000, multiplier: 2.0);
        var clock = new MutableSyncClock(10_000);
        var coordinator = new FirestoreSyncCoordinator(gateway, QuotaDomain(), clock, backoff);
        var changes = new List<SyncDomainChangeEvent>();
        var errors = new List<SyncDomainErrorEvent>();
        coordinator.DomainChanged += changes.Add;
        coordinator.DomainErrored += errors.Add;

        await coordinator.PollOnceAsync(); // initial success (d1)
        Assert.Single(changes);

        gateway.NextError = new InvalidOperationException("transient backend fault");
        SyncCycleResult failed1 = await coordinator.PollOnceAsync();
        SyncCycleResult failed2 = await coordinator.PollOnceAsync();

        // Fail-closed: last-known state is preserved, no spurious Removed changes.
        Assert.True(failed1.AnyFailed);
        Assert.Single(changes); // no new change events on failure
        Assert.Single(coordinator.LastKnownState(DomainName));
        Assert.Equal(2, errors.Count);
        Assert.Equal(1, errors[0].ConsecutiveFailures);
        Assert.Equal(1_000, errors[0].RetryDelayMillis);
        Assert.Equal(2, errors[1].ConsecutiveFailures);
        Assert.Equal(2_000, errors[1].RetryDelayMillis);           // exponential growth
        Assert.Equal(10_000 + 2_000, errors[1].RetryAtMillis);     // clock-stamped

        // Recover: the same doc is unchanged → no new change; failure counter resets.
        gateway.NextError = null;
        await coordinator.PollOnceAsync();
        Assert.Equal(0, coordinator.ConsecutiveFailures(DomainName));
        Assert.Single(changes);
    }

    // ── RunAsync loop cadence ────────────────────────────────────────────────
    [Fact]
    public async Task RunAsync_polls_on_interval_until_cancelled()
    {
        var gateway = new FakeCloudSyncGateway();
        gateway.SetDocumentData(Fields(("n", new CloudSyncValue.IntegerValue(1))), $"{QuotaPath}/d1");
        var pollInterval = TimeSpan.FromSeconds(30);
        var recordedDelays = new List<TimeSpan>();
        using var cts = new CancellationTokenSource();

        Task Delay(TimeSpan span, CancellationToken ct)
        {
            recordedDelays.Add(span);
            if (recordedDelays.Count >= 3) cts.Cancel();
            return Task.CompletedTask;
        }

        var coordinator = new FirestoreSyncCoordinator(
            gateway, QuotaDomain(), new MutableSyncClock(0), SyncBackoffPolicy.Default, pollInterval, Delay);

        await coordinator.RunAsync(cts.Token);

        Assert.Equal(3, recordedDelays.Count);
        Assert.All(recordedDelays, d => Assert.Equal(pollInterval, d)); // all-success cadence
    }

    [Fact]
    public async Task RunAsync_applies_backoff_delays_when_polls_fail()
    {
        var gateway = new FakeCloudSyncGateway { NextError = new InvalidOperationException("down") };
        var backoff = new SyncBackoffPolicy(baseDelayMillis: 1_000, maxDelayMillis: 60_000, multiplier: 2.0);
        var recordedDelays = new List<TimeSpan>();
        using var cts = new CancellationTokenSource();

        Task Delay(TimeSpan span, CancellationToken ct)
        {
            recordedDelays.Add(span);
            if (recordedDelays.Count >= 3) cts.Cancel();
            return Task.CompletedTask;
        }

        var coordinator = new FirestoreSyncCoordinator(
            gateway, QuotaDomain(), new MutableSyncClock(0), backoff, TimeSpan.FromSeconds(30), Delay);

        await coordinator.RunAsync(cts.Token);

        Assert.Equal(new[] { 1_000.0, 2_000.0, 4_000.0 }, recordedDelays.Select(d => d.TotalMilliseconds).ToArray());
    }

    // ── Real gateway path: RecordingTransport replays Firestore runQuery ──────
    [Fact]
    public async Task Coordinator_pulls_real_documents_through_the_rest_gateway()
    {
        var responses = new Queue<CloudSyncHttpResponse>();
        responses.Enqueue(RunQueryResponse(("d1", IntField(1))));
        responses.Enqueue(RunQueryResponse(("d1", IntField(2)), ("d2", IntField(3))));
        var transport = new RecordingTransport(_ => responses.Dequeue());
        FirestoreRestGateway gateway = RestGateway(transport);

        var coordinator = new FirestoreSyncCoordinator(gateway, QuotaDomain(), new MutableSyncClock(0));
        var events = new List<SyncDomainChangeEvent>();
        coordinator.DomainChanged += events.Add;

        await coordinator.PollOnceAsync(); // initial: d1=1 Added
        await coordinator.PollOnceAsync(); // d1 1→2 Modified, d2 Added

        Assert.EndsWith(":runQuery", transport.Requests[0].Url);
        SyncDomainChangeEvent initial = events[0];
        Assert.True(initial.FromInitial);
        Assert.Equal("d1", Assert.Single(initial.Changes).DocumentId);

        SyncDomainChangeEvent second = events[1];
        Assert.False(second.FromInitial);
        Assert.Equal(SyncChangeKind.Modified, second.Changes.Single(c => c.DocumentId == "d1").Kind);
        Assert.Equal(2, ((CloudSyncValue.IntegerValue)second.Changes.Single(c => c.DocumentId == "d1").Data["n"]!).Value);
        Assert.Equal(SyncChangeKind.Added, second.Changes.Single(c => c.DocumentId == "d2").Kind);
    }

    [Fact]
    public async Task App_check_required_but_missing_fails_closed_in_the_orchestrator()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200, "[]"));
        FirestoreRestGateway gateway = RestGateway(transport, appCheck: null, requireAppCheck: true);

        var coordinator = new FirestoreSyncCoordinator(gateway, QuotaDomain(), new MutableSyncClock(0));
        var changes = new List<SyncDomainChangeEvent>();
        var errors = new List<SyncDomainErrorEvent>();
        coordinator.DomainChanged += changes.Add;
        coordinator.DomainErrored += errors.Add;

        SyncCycleResult result = await coordinator.PollOnceAsync();

        Assert.True(result.AnyFailed);
        Assert.Empty(changes);                         // never delivered a snapshot
        Assert.Empty(transport.Requests);              // never transmitted (fail-closed)
        SyncDomainErrorEvent error = Assert.Single(errors);
        Assert.IsType<CloudSyncGatewayException>(error.Error);
        Assert.Empty(coordinator.LastKnownState(DomainName));
    }

    // ── Helpers ──────────────────────────────────────────────────────────────
    private static FirestoreRestGateway RestGateway(
        RecordingTransport transport, string? appCheck = "appcheck-tok", bool requireAppCheck = true) =>
        new(transport, new StaticCredentialsProvider(new CloudSyncCredentials("id-token", appCheck)),
            new FirestoreDatabase("proj"), requireAppCheck);

    private static string IntField(long n) => $"{{\"n\":{{\"integerValue\":\"{n}\"}}}}";

    private static CloudSyncHttpResponse RunQueryResponse(params (string Id, string FieldsJson)[] docs)
    {
        IEnumerable<string> elements = docs.Select(d =>
            $"{{\"document\":{{\"name\":\"projects/proj/databases/(default)/documents/{QuotaPath}/{d.Id}\"," +
            $"\"fields\":{d.FieldsJson}}}}}");
        return RecordingTransport.Json(200, "[" + string.Join(",", elements) + "]");
    }
}
