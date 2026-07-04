using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Memories;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported memory-review inbox model
/// (windows/app/OpenBurnBar.App.Presentation/Memory/MemoryReviewInboxModel.cs), the
/// human gate in the quarantine lifecycle (G4). Drives the model with in-memory fakes
/// exactly as the Swift MemoryReviewInboxModelTests drive the original.
/// </summary>
public sealed class MemoryReviewInboxModelTests
{
    private static readonly MemoryScope Scope = new(UserId: "u1", AgentId: "a1");

    private static Memory MakeMemory(string id, MemoryReviewStatus status, double confidence = 0.6, MemoryKind kind = MemoryKind.Fact)
    {
        var now = DateTimeOffset.UnixEpoch;
        return new Memory(
            Id: id,
            Kind: kind,
            Scope: Scope,
            Confidence: confidence,
            BodyRedacted: $"sealed::{id}",
            ReviewStatus: status,
            Citations: Array.Empty<MemoryCitation>(),
            ValidFrom: now,
            CreatedAt: now,
            UpdatedAt: now);
    }

    [Fact]
    public async Task Load_PartitionsQuarantinedIntoPending_AndApprovedIntoApproved()
    {
        var store = new FakeMemoryStore(new[]
        {
            MakeMemory("q1", MemoryReviewStatus.Quarantined),
            MakeMemory("q2", MemoryReviewStatus.Quarantined),
            MakeMemory("a1", MemoryReviewStatus.Approved),
            MakeMemory("r1", MemoryReviewStatus.Rejected),
        });
        store.SetBody("q1", "remembers espresso over drip");
        store.SetBody("q2", "prefers dark mode");
        store.SetBody("a1", "works in Pacific time");

        var model = store.BuildModel();
        await model.LoadAsync();

        Assert.Null(model.ErrorMessage);
        Assert.False(model.IsLoading);
        Assert.Equal(new[] { "q1", "q2" }, model.Pending.Select(i => i.Id));
        Assert.Equal(new[] { "a1" }, model.Approved.Select(i => i.Id));
        Assert.Equal(2, model.PendingCount);

        // Rejected rows appear in neither bucket.
        Assert.DoesNotContain("r1", model.Pending.Select(i => i.Id));
        Assert.DoesNotContain("r1", model.Approved.Select(i => i.Id));

        // Pending bucket requested quarantined rows; approved bucket did not.
        Assert.Contains(store.Requests, r => r.IncludeQuarantined);
        Assert.Contains(store.Requests, r => !r.IncludeQuarantined);
    }

    [Fact]
    public async Task Items_ReflectsFilter()
    {
        var store = new FakeMemoryStore(new[]
        {
            MakeMemory("q1", MemoryReviewStatus.Quarantined),
            MakeMemory("a1", MemoryReviewStatus.Approved),
        });
        store.SetBody("q1", "body q1");
        store.SetBody("a1", "body a1");

        var model = store.BuildModel();
        await model.LoadAsync();

        Assert.Equal(MemoryReviewInboxModel.Filter.Pending, model.CurrentFilter);
        Assert.Equal(new[] { "q1" }, model.Items.Select(i => i.Id));

        model.CurrentFilter = MemoryReviewInboxModel.Filter.Approved;
        Assert.Equal(new[] { "a1" }, model.Items.Select(i => i.Id));
    }

    [Fact]
    public async Task Load_OpensBody_MarksLoadedWhenPresent()
    {
        var store = new FakeMemoryStore(new[] { MakeMemory("q1", MemoryReviewStatus.Quarantined) });
        store.SetBody("q1", "the real transient body");

        var model = store.BuildModel();
        await model.LoadAsync();

        var item = Assert.Single(model.Pending);
        Assert.Equal(MemoryBodyLoadState.Loaded, item.BodyLoadState);
        Assert.Equal("the real transient body", item.Body);
        Assert.True(item.CanApprove);
    }

    [Fact]
    public async Task Load_MarksUnavailable_WhenBodyNullOrWhitespace()
    {
        var store = new FakeMemoryStore(new[]
        {
            MakeMemory("qNull", MemoryReviewStatus.Quarantined),
            MakeMemory("qBlank", MemoryReviewStatus.Quarantined),
        });
        store.SetBody("qNull", null);      // opener returns null
        store.SetBody("qBlank", "   \n ");  // opener returns whitespace

        var model = store.BuildModel();
        await model.LoadAsync();

        foreach (var item in model.Pending)
        {
            Assert.Equal(MemoryBodyLoadState.Unavailable, item.BodyLoadState);
            Assert.False(item.CanApprove);
        }
    }

    [Fact]
    public async Task Load_MarksUnavailable_WhenOpenBodyThrows()
    {
        var store = new FakeMemoryStore(new[] { MakeMemory("q1", MemoryReviewStatus.Quarantined) });
        store.ThrowOnOpenBody("q1");

        var model = store.BuildModel();
        await model.LoadAsync();

        var item = Assert.Single(model.Pending);
        Assert.Equal(MemoryBodyLoadState.Unavailable, item.BodyLoadState);
        Assert.False(item.CanApprove);
        // A body-open failure is best-effort — it does NOT fail the whole load.
        Assert.Null(model.ErrorMessage);
    }

    [Fact]
    public async Task Approve_MovesMemoryFromPendingToApproved()
    {
        var store = new FakeMemoryStore(new[] { MakeMemory("q1", MemoryReviewStatus.Quarantined) });
        store.SetBody("q1", "approve me");

        var model = store.BuildModel();
        await model.LoadAsync();
        Assert.Single(model.Pending);

        await model.ApproveAsync("q1");

        Assert.Empty(model.Pending);
        Assert.Equal(new[] { "q1" }, model.Approved.Select(i => i.Id));
        Assert.Equal((("q1", MemoryReviewStatus.Approved)), store.StatusChanges.Single());
    }

    [Fact]
    public async Task Approve_Blocked_WhenBodyUnavailable_SetsError_AndSkipsSetStatus()
    {
        var store = new FakeMemoryStore(new[] { MakeMemory("q1", MemoryReviewStatus.Quarantined) });
        store.SetBody("q1", null); // unavailable → not approvable

        var model = store.BuildModel();
        await model.LoadAsync();

        await model.ApproveAsync("q1");

        Assert.NotNull(model.ErrorMessage);
        Assert.Contains("unavailable", model.ErrorMessage!, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(store.StatusChanges);           // never attempted the transition
        Assert.Single(model.Pending);                 // still pending
    }

    [Fact]
    public async Task Reject_RemovesFromPending_AndCallsSetStatusRejected()
    {
        var store = new FakeMemoryStore(new[]
        {
            MakeMemory("q1", MemoryReviewStatus.Quarantined),
            MakeMemory("q2", MemoryReviewStatus.Quarantined),
        });
        store.SetBody("q1", "b1");
        store.SetBody("q2", "b2");

        var model = store.BuildModel();
        await model.LoadAsync();

        await model.RejectAsync("q1");

        Assert.Equal(new[] { "q2" }, model.Pending.Select(i => i.Id));
        Assert.DoesNotContain("q1", model.Approved.Select(i => i.Id));
        Assert.Equal((("q1", MemoryReviewStatus.Rejected)), store.StatusChanges.Single());
    }

    [Fact]
    public async Task Load_MapsGenericError_ToDefaultFriendlyMessage()
    {
        var store = new FakeMemoryStore(Array.Empty<Memory>());
        store.FailLoadWith(new InvalidOperationException("boom (internal)"));

        var model = store.BuildModel();
        await model.LoadAsync();

        Assert.False(model.IsLoading);
        Assert.NotNull(model.ErrorMessage);
        Assert.DoesNotContain("boom", model.ErrorMessage!); // internal detail is NOT leaked
        Assert.Contains("Something went wrong", model.ErrorMessage!);
    }

    [Fact]
    public async Task Load_UsesFriendlyMessage_WhenErrorProvidesOne()
    {
        var store = new FakeMemoryStore(Array.Empty<Memory>());
        store.FailLoadWith(new FriendlyTestException("Your memory vault is locked."));

        var model = store.BuildModel();
        await model.LoadAsync();

        Assert.Equal("Your memory vault is locked.", model.ErrorMessage);
    }

    [Fact]
    public async Task Load_CapsBucketAtPageSize_FromFirstFullPage()
    {
        // 250 quarantined rows: page 1 already returns 200 kept rows, which hits the
        // page-size cap, so the loop stops WITHOUT fetching page 2 — faithful to the
        // Swift `while items.count < pageSize` bound. (Page 2 is only fetched when page 1
        // yields fewer than pageSize KEPT rows — see PaginatesPastSkippedRows.)
        var memories = Enumerable.Range(0, 250)
            .Select(n => MakeMemory($"q{n:D3}", MemoryReviewStatus.Quarantined))
            .ToArray();
        var store = new FakeMemoryStore(memories);
        foreach (var m in memories)
        {
            store.SetBody(m.Id, $"body {m.Id}");
        }

        var model = store.BuildModel();
        await model.LoadAsync();

        Assert.Equal(200, model.PendingCount); // capped at the page-size bound, like Swift
        Assert.Contains(store.Requests, r => r.IncludeQuarantined && r.Page == 1);
        Assert.DoesNotContain(store.Requests, r => r.IncludeQuarantined && r.Page == 2);
    }

    [Fact]
    public async Task PaginatesPastSkippedRows_ToFindKeptRowsOnLaterPage()
    {
        // Pending bucket keeps only quarantined. Page 1 is all approved (skipped);
        // the quarantined row lives on page 2. The loop must not stop early.
        var memories = new List<Memory>();
        for (int n = 0; n < 200; n++)
        {
            memories.Add(MakeMemory($"a{n:D3}", MemoryReviewStatus.Approved));
        }

        memories.Add(MakeMemory("qLate", MemoryReviewStatus.Quarantined));
        var store = new FakeMemoryStore(memories.ToArray());
        store.SetBody("qLate", "found on page two");

        var model = store.BuildModel();
        await model.LoadAsync();

        Assert.Equal(new[] { "qLate" }, model.Pending.Select(i => i.Id));
    }

    [Fact]
    public async Task Load_RaisesPropertyChanged_ForBucketsAndLoading()
    {
        var store = new FakeMemoryStore(new[] { MakeMemory("q1", MemoryReviewStatus.Quarantined) });
        store.SetBody("q1", "b1");
        var model = store.BuildModel();

        var changed = new List<string>();
        model.PropertyChanged += (_, e) => changed.Add(e.PropertyName ?? string.Empty);

        await model.LoadAsync();

        Assert.Contains(nameof(model.IsLoading), changed);
        Assert.Contains(nameof(model.Pending), changed);
        Assert.Contains(nameof(model.PendingCount), changed);
    }

    private sealed class FriendlyTestException : Exception, IFriendlyError
    {
        public FriendlyTestException(string friendly) : base("internal-" + friendly)
        {
            FriendlyMessage = friendly;
        }

        public string? FriendlyMessage { get; }
    }

    /// <summary>In-memory backing for the inbox model's three injected delegates.</summary>
    private sealed class FakeMemoryStore
    {
        private readonly List<Memory> _memories;
        private readonly Dictionary<string, string?> _bodies = new(StringComparer.Ordinal);
        private readonly HashSet<string> _throwBodies = new(StringComparer.Ordinal);
        private Exception? _loadFailure;

        public FakeMemoryStore(IEnumerable<Memory> memories)
        {
            _memories = memories.ToList();
        }

        public List<MemoryPageRequest> Requests { get; } = new();

        public List<(string Id, MemoryReviewStatus Status)> StatusChanges { get; } = new();

        public void SetBody(string id, string? body) => _bodies[id] = body;

        public void ThrowOnOpenBody(string id) => _throwBodies.Add(id);

        public void FailLoadWith(Exception error) => _loadFailure = error;

        public MemoryReviewInboxModel BuildModel() =>
            new(Scope, LoadPageAsync, OpenBodyAsync, SetStatusAsync);

        private Task<MemoryPage> LoadPageAsync(MemoryPageRequest request)
        {
            Requests.Add(request);
            if (_loadFailure is not null)
            {
                throw _loadFailure;
            }

            IEnumerable<Memory> visible = request.IncludeQuarantined
                ? _memories
                : _memories.Where(m => m.ReviewStatus != MemoryReviewStatus.Quarantined);

            var visibleList = visible.ToList();
            var slice = visibleList
                .Skip((request.Page - 1) * request.PageSize)
                .Take(request.PageSize)
                .ToList();

            return Task.FromResult(new MemoryPage(slice, request.Page, request.PageSize, visibleList.Count));
        }

        private Task<string?> OpenBodyAsync(string id)
        {
            if (_throwBodies.Contains(id))
            {
                throw new InvalidOperationException("seal open failed");
            }

            return Task.FromResult(_bodies.TryGetValue(id, out var body) ? body : null);
        }

        private Task<bool> SetStatusAsync(string id, MemoryReviewStatus status)
        {
            StatusChanges.Add((id, status));
            for (int i = 0; i < _memories.Count; i++)
            {
                if (string.Equals(_memories[i].Id, id, StringComparison.Ordinal))
                {
                    _memories[i] = _memories[i] with { ReviewStatus = status };
                    break;
                }
            }

            return Task.FromResult(true);
        }
    }
}

public sealed class MemoryStoreTests
{
    [Fact]
    public async Task DefaultStore_IsEmpty_NeverInventDemoFacts()
    {
        var store = new MemoryStore();
        var page = await store.LoadPageAsync(new MemoryPageRequest(
            Scope: new MemoryScope(AppId: "openburnbar"),
            Page: 1,
            PageSize: 50,
            IncludeQuarantined: true));

        Assert.Empty(page.Items);
        Assert.Equal(0, page.Total);
    }

    [Fact]
    public async Task SetStatus_SurfacesMacOnlyFriendlyMessage()
    {
        var store = new MemoryStore();
        var error = await Assert.ThrowsAsync<MemoryReviewMacOnlyException>(
            () => store.SetStatusAsync("mem-1", MemoryReviewStatus.Approved));
        Assert.Contains("Review on your Mac", error.FriendlyMessage);
    }

    [Fact]
    public async Task ReadOnlyModel_DefaultsToApprovedFilter_AndBlocksApprove()
    {
        var now = DateTimeOffset.UtcNow;
        var facts = new[]
        {
            new SyncedMemoryFact(
                Id: "a1",
                Kind: MemoryKind.Preference,
                Scope: new MemoryScope(AppId: "openburnbar"),
                Confidence: 0.9,
                BodyRedacted: "sealed::a1",
                PlaintextBody: "prefers dark mode",
                ReviewStatus: MemoryReviewStatus.Approved,
                Citations: Array.Empty<MemoryCitation>(),
                ValidFrom: now,
                CreatedAt: now,
                UpdatedAt: now),
        };
        var store = new MemoryStore(facts);
        var model = new MemoryReviewInboxModel(
            new MemoryScope(AppId: "openburnbar"),
            store.LoadPageAsync,
            store.OpenBodyAsync,
            store.SetStatusAsync,
            readOnly: true);

        await model.LoadAsync();

        Assert.True(model.IsReadOnly);
        Assert.False(model.AllowsReviewActions);
        Assert.Equal(MemoryReviewInboxModel.Filter.Approved, model.CurrentFilter);
        Assert.Single(model.Items);
        Assert.False(model.Items[0].ShowReviewActions);

        await model.ApproveAsync("a1");
        Assert.Contains("Review on your Mac", model.ErrorMessage);
    }
}
