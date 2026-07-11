using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// PORTED (faithful, scoped) from AgentLens/Services/DataControlCenterViewModel.swift.
//
// The callable hub + inventory state for the Data & Privacy Control Center. The inventory is
// seeded from the generated registry (DataDomains.All) so all 12 domains render before the
// network lands, then merged with the live getDataDomainUsage snapshot. Every mutation routes
// through IDataControlCallableHub; errors distill through DataControlErrorMapping so the workbench
// never leaks a raw Functions string.
//
// Swift `@Observable @MainActor` becomes INotifyPropertyChanged here (WinUI x:Bind refreshes); the
// UI-thread affinity is the caller's responsibility on Windows (the view drives it from the
// DispatcherQueue). The logic itself is portable + deterministic — which is what the macOS
// `dotnet test` exercises with an in-memory fake hub.

/// <summary>View-model backing the Windows Data Control Center governance workbench.</summary>
public sealed class DataControlCenterViewModel : INotifyPropertyChanged
{
    private readonly IDataControlCallableHub _hub;

    private IReadOnlyList<DomainRow> _rows;
    private SortDescriptor _sortDescriptor = SortDescriptor.Default;
    private AccountPlanTier _tier = AccountPlanTier.Free;
    private PensieveLimits _pensieveLimits = PensieveLimits.Empty;
    private string? _selectedId;

    private bool _isLoadingUsage;
    private string? _usageError;
    private bool _isExporting;
    private bool _isMutating;
    private string? _actionError;

    private bool _isLoadingRecovery;
    private bool _isLoadingAudit;
    private string? _auditNextCursor;
    private AuditVerification? _auditVerification;

    public DataControlCenterViewModel(IDataControlCallableHub? hub = null)
    {
        _hub = hub ?? SignedOutCallableHub.Instance;

        // Seed the inventory from the registry immediately so the workbench renders all 12 domains
        // before the network call lands (Swift: the constructor's registry seed).
        _rows = DataDomains.All.Select(d => new DomainRow(d, 0, 0)).ToList();
    }

    // ── Inventory ────────────────────────────────────────────────────────────────────────────

    /// <summary>All inventory rows in registry order (unsorted). Swift: <c>rows</c>.</summary>
    public IReadOnlyList<DomainRow> Rows => _rows;

    /// <summary>The rows sorted by the current <see cref="SortDescriptor"/> (the DataGrid source).</summary>
    public IReadOnlyList<DomainRow> SortedRows => DataControlSorting.Sort(_rows, _sortDescriptor);

    /// <summary>The tier-grouped sidebar sections (End-to-end, Zero-access, Server-readable).</summary>
    public IReadOnlyList<TierSection> TierSections => DataControlSorting.TierSections(_rows);

    /// <summary>The active inventory sort. Setting it re-projects <see cref="SortedRows"/>.</summary>
    public SortDescriptor SortDescriptor
    {
        get => _sortDescriptor;
        set
        {
            if (_sortDescriptor != value)
            {
                _sortDescriptor = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(SortedRows));
            }
        }
    }

    /// <summary>Toggle the sort for a column (or switch to it). Drives the DataGrid header click.</summary>
    public void ApplySort(SortColumn column) => SortDescriptor = _sortDescriptor.ToggledFor(column);

    /// <summary>The current plan tier echoed by getDataDomainUsage. Swift: <c>tier</c>.</summary>
    public AccountPlanTier Tier
    {
        get => _tier;
        private set { if (_tier != value) { _tier = value; OnPropertyChanged(); } }
    }

    /// <summary>The Pensieve hard caps for the current plan. Swift: <c>pensieveLimits</c>.</summary>
    public PensieveLimits PensieveLimits
    {
        get => _pensieveLimits;
        private set { if (!_pensieveLimits.Equals(value)) { _pensieveLimits = value; OnPropertyChanged(); } }
    }

    /// <summary>
    /// The Basin substance level — the sealed (zero-access + end-to-end) share of the footprint.
    /// Drives the mercury-swirl fill height. Swift: <c>sealedFraction</c>.
    /// </summary>
    public double SealedFraction => DataControlSorting.SealedFraction(_rows);

    /// <summary>The Basin caption ("<c>NN% sealed</c>").</summary>
    public string BasinCaption => BasinModel.SealedCaption(SealedFraction);

    /// <summary>The selected domain id (inventory + sidebar selection).</summary>
    public string? SelectedId
    {
        get => _selectedId;
        set
        {
            if (_selectedId != value)
            {
                _selectedId = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(SelectedRow));
            }
        }
    }

    /// <summary>The selected inventory row, or <c>null</c>.</summary>
    public DomainRow? SelectedRow => _selectedId is null ? null : Row(_selectedId);

    /// <summary>Resolve a row by domain id. Swift: <c>row(for:)</c>.</summary>
    public DomainRow? Row(string id) => _rows.FirstOrDefault(r => r.Id == id);

    // ── Flags + errors ───────────────────────────────────────────────────────────────────────

    public bool IsLoadingUsage
    {
        get => _isLoadingUsage;
        private set { if (_isLoadingUsage != value) { _isLoadingUsage = value; OnPropertyChanged(); } }
    }

    public string? UsageError
    {
        get => _usageError;
        private set { if (_usageError != value) { _usageError = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasUsageError)); } }
    }

    public bool HasUsageError => _usageError is not null;

    public bool IsExporting
    {
        get => _isExporting;
        private set { if (_isExporting != value) { _isExporting = value; OnPropertyChanged(); } }
    }

    public bool IsMutating
    {
        get => _isMutating;
        private set { if (_isMutating != value) { _isMutating = value; OnPropertyChanged(); } }
    }

    public string? ActionError
    {
        get => _actionError;
        private set { if (_actionError != value) { _actionError = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasActionError)); } }
    }

    public bool HasActionError => _actionError is not null;

    public bool IsLoadingRecovery
    {
        get => _isLoadingRecovery;
        private set { if (_isLoadingRecovery != value) { _isLoadingRecovery = value; OnPropertyChanged(); } }
    }

    public bool IsLoadingAudit
    {
        get => _isLoadingAudit;
        private set { if (_isLoadingAudit != value) { _isLoadingAudit = value; OnPropertyChanged(); } }
    }

    /// <summary>Registered recovery methods (observable so the recovery dialog refreshes).</summary>
    public ObservableCollection<RecoveryMethod> RecoveryMethods { get; } = new();

    /// <summary>Loaded audit events (observable so the audit card refreshes).</summary>
    public ObservableCollection<AuditEvent> AuditEvents { get; } = new();

    /// <summary>Whether another audit page is available. Swift: <c>auditNextCursor != nil</c>.</summary>
    public bool HasMoreAudit => _auditNextCursor is not null;

    /// <summary>The last chain verification, or <c>null</c>. Swift: <c>auditVerification</c>.</summary>
    public AuditVerification? AuditVerification
    {
        get => _auditVerification;
        private set { _auditVerification = value; OnPropertyChanged(); }
    }

    // ── Usage (getDataDomainUsage) ───────────────────────────────────────────────────────────

    /// <summary>Refresh the live footprint + tier + caps, rebuilding the inventory. Swift: <c>refreshUsage</c>.</summary>
    public async Task RefreshUsageAsync()
    {
        if (!_hub.IsSignedIn)
        {
            UsageError = "Sign in to OpenBurnBar to view your data.";
            return;
        }

        IsLoadingUsage = true;
        UsageError = null;
        try
        {
            var snapshot = await _hub.GetUsageAsync().ConfigureAwait(false);
            ApplyUsage(snapshot);
        }
        catch (Exception error)
        {
            UsageError = DataControlErrorMapping.UserFacing(error);
        }
        finally
        {
            IsLoadingUsage = false;
        }
    }

    /// <summary>Merge a usage snapshot into the registry-ordered inventory. Swift: <c>applyUsage</c>.</summary>
    public void ApplyUsage(DataDomainUsageSnapshot snapshot)
    {
        Tier = snapshot.Tier;
        PensieveLimits = snapshot.PensieveLimits;

        _rows = DataDomains.All.Select(domain =>
        {
            var usage = snapshot.UsageById.TryGetValue(domain.Id, out var u) ? u : default;
            return new DomainRow(domain, usage.Count, usage.Bytes);
        }).ToList();

        RaiseInventoryChanged();
    }

    // ── Export (exportUserData) ──────────────────────────────────────────────────────────────

    /// <summary>Return the export JSON for <paramref name="domains"/> (null = all). Swift: <c>exportData</c>.</summary>
    public async Task<string?> ExportDataAsync(IReadOnlyList<string>? domains)
    {
        if (!_hub.IsSignedIn)
        {
            ActionError = "Sign in to OpenBurnBar to export your data.";
            return null;
        }

        IsExporting = true;
        ActionError = null;
        try
        {
            return await _hub.ExportAsync(domains).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
            return null;
        }
        finally
        {
            IsExporting = false;
        }
    }

    /// <summary>Surface a local export-write failure with the same calm copy as network errors.</summary>
    public void SetExportWriteError(Exception error) => ActionError = DataControlErrorMapping.UserFacing(error);

    // ── Delete (deleteDomainData) ────────────────────────────────────────────────────────────

    /// <summary>Delete a domain, then refresh usage. Swift: <c>deleteDomain</c>.</summary>
    public async Task<DeleteResult?> DeleteDomainAsync(string domainId)
    {
        if (!_hub.IsSignedIn)
        {
            ActionError = "Sign in to OpenBurnBar to delete your data.";
            return null;
        }

        IsMutating = true;
        ActionError = null;
        try
        {
            var result = await _hub.DeleteDomainAsync(domainId).ConfigureAwait(false);
            await RefreshUsageAsync().ConfigureAwait(false);
            return result;
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
            return null;
        }
        finally
        {
            IsMutating = false;
        }
    }

    // ── Recovery (listRecovery / setupRecovery / confirmRecovery) ─────────────────────────────

    /// <summary>Refresh the registered recovery methods. Swift: <c>refreshRecovery</c>.</summary>
    public async Task RefreshRecoveryAsync()
    {
        if (!_hub.IsSignedIn)
        {
            return;
        }

        IsLoadingRecovery = true;
        try
        {
            var methods = await _hub.ListRecoveryAsync().ConfigureAwait(false);
            ReplaceCollection(RecoveryMethods, methods);
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
        }
        finally
        {
            IsLoadingRecovery = false;
        }
    }

    /// <summary>Register a recovery method, then refresh. Returns the recovery id. Swift: <c>setupRecovery</c>.</summary>
    public async Task<string?> SetupRecoveryAsync(RecoveryKind method, IReadOnlyDictionary<string, object?> payload)
    {
        if (!_hub.IsSignedIn)
        {
            ActionError = "Sign in to OpenBurnBar to set up recovery.";
            return null;
        }

        IsMutating = true;
        ActionError = null;
        try
        {
            var recoveryId = await _hub.SetupRecoveryAsync(method, payload).ConfigureAwait(false);
            await RefreshRecoveryAsync().ConfigureAwait(false);
            return recoveryId;
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
            return null;
        }
        finally
        {
            IsMutating = false;
        }
    }

    /// <summary>Confirm a recovery method, then refresh. Swift: <c>confirmRecovery</c>.</summary>
    public async Task<bool> ConfirmRecoveryAsync(string recoveryId, string? verificationHash = null)
    {
        if (!_hub.IsSignedIn)
        {
            return false;
        }

        IsMutating = true;
        ActionError = null;
        try
        {
            bool ok = await _hub.ConfirmRecoveryAsync(recoveryId, verificationHash).ConfigureAwait(false);
            await RefreshRecoveryAsync().ConfigureAwait(false);
            return ok;
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
            return false;
        }
        finally
        {
            IsMutating = false;
        }
    }

    // ── Panic (revokeAllAccess) ──────────────────────────────────────────────────────────────

    /// <summary>Revoke access at <paramref name="scope"/>, then refresh usage. Swift: <c>revokeAllAccess</c>.</summary>
    public async Task<RevokeResult?> RevokeAllAccessAsync(RevokeScope scope)
    {
        if (!_hub.IsSignedIn)
        {
            ActionError = "Sign in to OpenBurnBar to revoke access.";
            return null;
        }

        IsMutating = true;
        ActionError = null;
        try
        {
            var result = await _hub.RevokeAllAsync(scope).ConfigureAwait(false);
            await RefreshUsageAsync().ConfigureAwait(false);
            return result;
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
            return null;
        }
        finally
        {
            IsMutating = false;
        }
    }

    // ── Audit (getAuditLog / verifyAuditLog) ─────────────────────────────────────────────────

    /// <summary>Load (or page) the audit log. <paramref name="reset"/> replaces; else appends. Swift: <c>refreshAuditLog</c>.</summary>
    public async Task RefreshAuditLogAsync(bool reset = true)
    {
        if (!_hub.IsSignedIn)
        {
            return;
        }

        IsLoadingAudit = true;
        try
        {
            string? cursor = reset ? null : _auditNextCursor;
            var page = await _hub.GetAuditLogAsync(cursor, 100).ConfigureAwait(false);

            if (reset)
            {
                AuditEvents.Clear();
            }

            foreach (var evt in page.Events)
            {
                AuditEvents.Add(evt);
            }

            _auditNextCursor = page.NextCursor;
            OnPropertyChanged(nameof(HasMoreAudit));
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
        }
        finally
        {
            IsLoadingAudit = false;
        }
    }

    /// <summary>Verify the audit hash chain. Swift: <c>verifyAuditLog</c>.</summary>
    public async Task VerifyAuditLogAsync()
    {
        if (!_hub.IsSignedIn)
        {
            return;
        }

        IsMutating = true;
        ActionError = null;
        try
        {
            AuditVerification = await _hub.VerifyAuditLogAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            ActionError = DataControlErrorMapping.UserFacing(error);
        }
        finally
        {
            IsMutating = false;
        }
    }

    // ── Change notification ──────────────────────────────────────────────────────────────────

    private void RaiseInventoryChanged()
    {
        OnPropertyChanged(nameof(Rows));
        OnPropertyChanged(nameof(SortedRows));
        OnPropertyChanged(nameof(TierSections));
        OnPropertyChanged(nameof(SealedFraction));
        OnPropertyChanged(nameof(BasinCaption));
        OnPropertyChanged(nameof(SelectedRow));
    }

    private static void ReplaceCollection<T>(ObservableCollection<T> target, IEnumerable<T> items)
    {
        target.Clear();
        foreach (var item in items)
        {
            target.Add(item);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
