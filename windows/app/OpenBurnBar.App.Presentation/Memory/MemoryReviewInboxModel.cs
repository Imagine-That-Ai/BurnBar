using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Memories;

// PORTED (faithful) from AgentLens/Views/Memory/MemoryReviewInboxModel.swift.
//
// The inbox is the human gate in the quarantine lifecycle (G4): newly extracted
// memories land as `quarantined` and cannot be injected or replicated until the
// user approves them here. This model loads two buckets — pending (quarantined) and
// approved — opening each sealed body transiently for display only. It never
// persists or logs the opened body; the string lives only in `Item.Body` for the
// lifetime of the view.
//
// The delegates (LoadPage / OpenBody / SetStatus) are the seam the integrator wires
// to the real memory store; keeping them injected lets the tests drive the model
// with in-memory fakes — exactly as the Swift `@Observable @MainActor` original does.
//
// Swift `@Observable` becomes INotifyPropertyChanged here so WinUI x:Bind refreshes.
// Swift `@MainActor` (single-thread affinity) is the caller's responsibility on
// Windows (the view drives it from the UI DispatcherQueue); the logic itself is
// portable and deterministic, which is what the macOS `dotnet test` exercises.

/// <summary>
/// View-model backing the memory review inbox (Windows <c>MemoryReviewInboxView</c>).
/// </summary>
public sealed class MemoryReviewInboxModel : INotifyPropertyChanged
{
    /// <summary>Which bucket the inbox is showing. Swift: <c>enum Filter</c>.</summary>
    public enum Filter
    {
        Pending,
        Approved,
    }

    public delegate Task<MemoryPage> LoadPageDelegate(MemoryPageRequest request);

    public delegate Task<string?> OpenBodyDelegate(string memoryId);

    public delegate Task<bool> SetStatusDelegate(string memoryId, MemoryReviewStatus status);

    /// <summary>Largest page requested per bucket. The inbox is a review surface, not a
    /// paginated browser, so a single generous page bounds the fetch. Swift: <c>pageSize = 200</c>.</summary>
    private const int PageSize = 200;

    private const string DefaultErrorMessage =
        "Something went wrong loading your memories. Please try again.";

    private const string UnavailableBodyApprovalMessage =
        "Memory contents are unavailable. Reject it or reload before approving.";

    private readonly MemoryScope _scope;
    private readonly LoadPageDelegate _loadPage;
    private readonly OpenBodyDelegate _openBody;
    private readonly SetStatusDelegate _setStatus;
    private readonly bool _readOnly;

    private IReadOnlyList<MemoryReviewItem> _pending = Array.Empty<MemoryReviewItem>();
    private IReadOnlyList<MemoryReviewItem> _approved = Array.Empty<MemoryReviewItem>();
    private bool _isLoading;
    private string? _errorMessage;
    private Filter _filter = Filter.Pending;

    public MemoryReviewInboxModel(
        MemoryScope scope,
        LoadPageDelegate loadPage,
        OpenBodyDelegate openBody,
        SetStatusDelegate setStatus,
        bool readOnly = false)
    {
        _scope = scope ?? throw new ArgumentNullException(nameof(scope));
        _loadPage = loadPage ?? throw new ArgumentNullException(nameof(loadPage));
        _openBody = openBody ?? throw new ArgumentNullException(nameof(openBody));
        _setStatus = setStatus ?? throw new ArgumentNullException(nameof(setStatus));
        _readOnly = readOnly;
        if (readOnly)
        {
            _filter = Filter.Approved;
        }
    }

    /// <summary>
    /// Windows v1 is a read mirror of synced approved facts. Approve/reject stays Mac-owned (G4).
    /// </summary>
    public bool IsReadOnly => _readOnly;

    /// <summary>Whether approve/reject actions should be shown.</summary>
    public bool AllowsReviewActions => !_readOnly;

    public string TitleText => _readOnly ? "Synced memories" : "Approve what to remember";

    public string SubtitleText => _readOnly
        ? "Approved facts synced from your Mac appear here. Review and approve still happens on Mac — quarantined facts never leave that device."
        : "Memories stay quarantined until you approve them — nothing is used in a chat before you say so.";

    public string EmptyTitleText => _readOnly ? "No synced memories yet" : "No memories to review";

    public string EmptyBodyText => _readOnly
        ? "Once memory cloud sync is enabled on your Mac and approved facts replicate, they show up here read-only."
        : "When a chat turns up a durable fact or preference worth remembering, it lands here for your approval.";

    public IReadOnlyList<MemoryReviewItem> Pending
    {
        get => _pending;
        private set { _pending = value; OnPropertyChanged(); OnPropertyChanged(nameof(PendingCount)); OnPropertyChanged(nameof(HasPending)); OnPropertyChanged(nameof(PendingPillText)); RaiseDerived(); }
    }

    public IReadOnlyList<MemoryReviewItem> Approved
    {
        get => _approved;
        private set { _approved = value; OnPropertyChanged(); RaiseDerived(); }
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set { if (_isLoading != value) { _isLoading = value; OnPropertyChanged(); OnPropertyChanged(nameof(ShowEmpty)); } }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set { if (_errorMessage != value) { _errorMessage = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasError)); } }
    }

    public Filter CurrentFilter
    {
        get => _filter;
        set { if (_filter != value) { _filter = value; OnPropertyChanged(); RaiseDerived(); } }
    }

    /// <summary>The bucket currently shown. Swift: <c>items</c>.</summary>
    public IReadOnlyList<MemoryReviewItem> Items => _filter == Filter.Pending ? _pending : _approved;

    /// <summary>Badge count of memories awaiting review. Swift: <c>pendingCount</c>.</summary>
    public int PendingCount => _pending.Count;

    /// <summary>Whether the pending badge/pill should show. Swift: <c>model.pendingCount &gt; 0</c>.</summary>
    public bool HasPending => _pending.Count > 0;

    /// <summary>Pill label, e.g. "3 pending". Swift: the header pending pill text.</summary>
    public string PendingPillText => $"{_pending.Count} pending";

    /// <summary>Whether the current bucket has any rows (drives the list vs empty-state switch).</summary>
    public bool HasItems => Items.Count > 0;

    /// <summary>Show the empty state only when not loading and the bucket is empty.</summary>
    public bool ShowEmpty => !_isLoading && Items.Count == 0;

    /// <summary>Whether an error banner should show.</summary>
    public bool HasError => !string.IsNullOrEmpty(_errorMessage);

    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(Items));
        OnPropertyChanged(nameof(HasItems));
        OnPropertyChanged(nameof(ShowEmpty));
    }

    /// <summary>
    /// Loads both buckets: pending keeps only <c>Quarantined</c> (requesting quarantined
    /// rows), approved keeps only <c>Approved</c>. Each kept memory's sealed body is opened
    /// best-effort for display. Drives <see cref="IsLoading"/> and surfaces failures via
    /// <see cref="ErrorMessage"/>. Swift: <c>func load()</c>.
    /// </summary>
    public async Task LoadAsync()
    {
        IsLoading = true;
        ErrorMessage = null;
        try
        {
            var pendingItems = await LoadBucketAsync(includeQuarantined: true, keep: MemoryReviewStatus.Quarantined).ConfigureAwait(false);
            var approvedItems = await LoadBucketAsync(includeQuarantined: false, keep: MemoryReviewStatus.Approved).ConfigureAwait(false);
            Pending = pendingItems;
            Approved = approvedItems;
        }
        catch (Exception error)
        {
            ErrorMessage = FriendlyMessage(error);
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>Approves a memory, then reloads so it moves from pending to approved.
    /// Guarded on <c>CanApprove</c> like the Swift original. Swift: <c>func approve(_:)</c>.</summary>
    public async Task ApproveAsync(string id)
    {
        if (_readOnly)
        {
            ErrorMessage = new MemoryReviewMacOnlyException().FriendlyMessage;
            return;
        }

        var item = FindPending(id);
        if (item is null || !item.CanApprove)
        {
            ErrorMessage = UnavailableBodyApprovalMessage;
            return;
        }

        await TransitionAsync(id, MemoryReviewStatus.Approved).ConfigureAwait(false);
    }

    /// <summary>Rejects a memory, then reloads so it leaves the pending bucket.
    /// Swift: <c>func reject(_:)</c>.</summary>
    public Task RejectAsync(string id)
    {
        if (_readOnly)
        {
            ErrorMessage = new MemoryReviewMacOnlyException().FriendlyMessage;
            return Task.CompletedTask;
        }

        return TransitionAsync(id, MemoryReviewStatus.Rejected);
    }

    // MARK: - Private

    private MemoryReviewItem? FindPending(string id)
    {
        foreach (var item in _pending)
        {
            if (string.Equals(item.Id, id, StringComparison.Ordinal))
            {
                return item;
            }
        }

        return null;
    }

    private async Task TransitionAsync(string id, MemoryReviewStatus status)
    {
        try
        {
            _ = await _setStatus(id, status).ConfigureAwait(false);
            await LoadAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            ErrorMessage = FriendlyMessage(error);
        }
    }

    private async Task<IReadOnlyList<MemoryReviewItem>> LoadBucketAsync(bool includeQuarantined, MemoryReviewStatus keep)
    {
        var items = new List<MemoryReviewItem>(PageSize);
        int nextPage = 1;

        while (items.Count < PageSize)
        {
            var request = new MemoryPageRequest(
                Scope: _scope,
                Page: nextPage,
                PageSize: PageSize,
                IncludeQuarantined: includeQuarantined);

            var page = await _loadPage(request).ConfigureAwait(false);
            if (page.Items.Count == 0)
            {
                break;
            }

            foreach (var memory in page.Items)
            {
                if (memory.ReviewStatus != keep)
                {
                    continue;
                }

                string body;
                MemoryBodyLoadState state;
                try
                {
                    var opened = await _openBody(memory.Id).ConfigureAwait(false);
                    if (!string.IsNullOrWhiteSpace(opened))
                    {
                        body = opened!;
                        state = MemoryBodyLoadState.Loaded;
                    }
                    else
                    {
                        body = string.Empty;
                        state = MemoryBodyLoadState.Unavailable;
                    }
                }
                catch
                {
                    body = string.Empty;
                    state = MemoryBodyLoadState.Unavailable;
                }

                items.Add(new MemoryReviewItem(memory, body, state, ShowReviewActions: !_readOnly));
                if (items.Count >= PageSize)
                {
                    break;
                }
            }

            if (nextPage * PageSize >= page.Total)
            {
                break;
            }

            nextPage += 1;
        }

        return items;
    }

    private static string FriendlyMessage(Exception error) =>
        (error as IFriendlyError)?.FriendlyMessage ?? DefaultErrorMessage;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>Whether the sealed body opened for display. Swift: <c>Item.BodyLoadState</c>.</summary>
public enum MemoryBodyLoadState
{
    Loaded,
    Unavailable,
}

/// <summary>
/// One reviewable memory: the authority record plus its transiently-opened body.
/// Swift: <c>MemoryReviewInboxModel.Item</c> (top-level here so the WinUI DataTemplate
/// can name it in <c>x:DataType</c>). Body-derived display helpers live here so both
/// the model logic and the XAML row bind the same rules.
/// </summary>
public sealed record MemoryReviewItem(
    Memory Memory,
    string Body,
    MemoryBodyLoadState BodyLoadState,
    bool ShowReviewActions = true)
{
    public string Id => Memory.Id;

    /// <summary>Approvable only when the sealed body actually opened to non-empty text —
    /// mirrors the Swift <c>canApprove</c> guard that blocks approving an unavailable body.</summary>
    public bool CanApprove =>
        ShowReviewActions &&
        BodyLoadState == MemoryBodyLoadState.Loaded &&
        !string.IsNullOrWhiteSpace(Body);

    /// <summary>Row body text with the Swift fallback for an unavailable seal.
    /// Swift: <c>MemoryReviewRow.bodyText</c>.</summary>
    public string DisplayBody
    {
        get
        {
            string trimmed = Body.Trim();
            return trimmed.Length == 0 ? "(Memory contents unavailable)" : trimmed;
        }
    }

    /// <summary>Uppercase kind badge text. Swift: <c>item.memory.kind.rawValue</c> (uppercased).</summary>
    public string KindBadge => Memory.Kind.RawValue().ToUpperInvariant();

    /// <summary>Confidence as a whole-percent string. Swift: <c>confidencePercent</c>.</summary>
    public string ConfidenceLabel => $"{(int)System.Math.Round(Memory.Confidence * 100)}%";
}
