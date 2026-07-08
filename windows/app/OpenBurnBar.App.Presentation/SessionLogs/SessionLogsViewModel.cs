using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.SessionLogs;

// PORTED (faithful, scoped) from the state + memoized filter/group pipeline in
// AgentLens/Views/SessionLogs/SessionLogsView.swift. This drives the Windows
// NavigationView list-detail: the grouped command-center list on the left and the
// selected record on the right. Cloud/iCloud sync, device filtering, retrieval-health
// banners, resume, and export are macOS integrations that the port lights up in later
// waves; this view-model owns the local read + filter + group + select core.

/// <summary>View-model backing the Windows session-logs list-detail surface.</summary>
public sealed class SessionLogsViewModel : INotifyPropertyChanged
{
    private readonly ISessionLogReadSource _source;
    private readonly Func<DateTimeOffset> _now;

    private IReadOnlyList<SessionLogRecord> _allLogs = Array.Empty<SessionLogRecord>();
    private IReadOnlyList<SessionLogRecord> _filteredLogs = Array.Empty<SessionLogRecord>();
    private IReadOnlyList<string> _searchMatchedIds = Array.Empty<string>();
    private string _searchText = string.Empty;
    private SessionLogSourceFilter _sourceFilter = SessionLogSourceFilter.All;
    private SessionLogGroupMode _groupMode = SessionLogGroupMode.Time;
    private SessionLogDataSource _dataSource = SessionLogDataSource.Local;
    private string? _selectedId;
    private bool _isLoading;
    private string? _errorMessage;

    public SessionLogsViewModel(ISessionLogReadSource source, Func<DateTimeOffset>? now = null)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        _now = now ?? (() => DateTimeOffset.Now);
    }

    /// <summary>Grouped sections bound by the list (CollectionViewSource, ItemsPath=Logs).</summary>
    public ObservableCollection<SessionLogGroup> Groups { get; } = new();

    public IReadOnlyList<SessionLogRecord> FilteredLogs => _filteredLogs;

    public bool IsLoading
    {
        get => _isLoading;
        private set { if (_isLoading != value) { _isLoading = value; OnPropertyChanged(); } }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set { if (_errorMessage != value) { _errorMessage = value; OnPropertyChanged(); } }
    }

    public bool IsEmpty => _filteredLogs.Count == 0;

    public int FilteredCount => _filteredLogs.Count;

    public string CountLabel => $"{FilteredCount} log{(FilteredCount == 1 ? string.Empty : "s")}";

    public int ProviderCount => _filteredLogs.Select(l => l.Provider).Distinct(StringComparer.Ordinal).Count();

    public int ProjectCount => _filteredLogs.Select(l => l.ProjectName).Distinct(StringComparer.Ordinal).Count();

    public string SearchText
    {
        get => _searchText;
        set { if (_searchText != value) { _searchText = value ?? string.Empty; OnPropertyChanged(); } }
    }

    public SessionLogSourceFilter SourceFilter
    {
        get => _sourceFilter;
        set { if (_sourceFilter != value) { _sourceFilter = value; OnPropertyChanged(); Rebuild(); } }
    }

    public SessionLogGroupMode GroupMode
    {
        get => _groupMode;
        set { if (_groupMode != value) { _groupMode = value; OnPropertyChanged(); Rebuild(); } }
    }

    public SessionLogDataSource DataSource
    {
        get => _dataSource;
        set { if (_dataSource != value) { _dataSource = value; OnPropertyChanged(); Rebuild(); } }
    }

    public string? SelectedId
    {
        get => _selectedId;
        set { if (_selectedId != value) { _selectedId = value; OnPropertyChanged(); OnPropertyChanged(nameof(SelectedLog)); } }
    }

    /// <summary>The currently selected record, or <c>null</c>. Swift: <c>selectedLog</c>.</summary>
    public SessionLogRecord? SelectedLog =>
        _selectedId is null ? null : _allLogs.FirstOrDefault(l => l.Id == _selectedId);

    /// <summary>Loads the local log set and rebuilds the grouped list. Swift: <c>loadLogs()</c>.</summary>
    public async Task LoadAsync()
    {
        IsLoading = true;
        ErrorMessage = null;
        try
        {
            _allLogs = await _source.ListAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            ErrorMessage = error is Presentation.Memories.IFriendlyError fe && fe.FriendlyMessage is not null
                ? fe.FriendlyMessage
                : "Couldn't load your session logs. Please try again.";
            _allLogs = Array.Empty<SessionLogRecord>();
        }
        finally
        {
            IsLoading = false;
        }

        Rebuild();
    }

    /// <summary>
    /// Applies a search query. On the Local source this queries the read seam for the
    /// matched ids (FTS/retrieval) and projects them in rank order; on Cloud/iCloud the
    /// substring path in <see cref="SessionLogGrouping"/> handles it. Swift: the
    /// <c>handleSearchTextChange</c> → retrieval-search → <c>retrievalMatchedIDs</c> flow.
    /// </summary>
    public async Task UpdateSearchAsync(string text)
    {
        SearchText = text ?? string.Empty;
        string trimmed = SearchText.Trim();

        if (trimmed.Length == 0)
        {
            _searchMatchedIds = Array.Empty<string>();
        }
        else if (_dataSource == SessionLogDataSource.Local)
        {
            try
            {
                _searchMatchedIds = await _source.SearchMatchingIdsAsync(trimmed).ConfigureAwait(false);
            }
            catch
            {
                _searchMatchedIds = Array.Empty<string>();
            }
        }

        Rebuild();
    }

    /// <summary>Recomputes the filtered set + grouped sections. Swift: <c>rebuildLogGroupsIfNeeded</c>.</summary>
    public void Rebuild()
    {
        _filteredLogs = SessionLogGrouping.ComputeFilteredLogs(
            allLogs: _allLogs,
            sourceFilter: _sourceFilter,
            deviceFilter: null,
            localDeviceId: null,
            searchText: _searchText,
            dataSource: _dataSource,
            searchMatchedIds: _searchMatchedIds);

        var groups = SessionLogGrouping.ComputeLogGroups(_filteredLogs, _groupMode, _now());

        Groups.Clear();
        foreach (var group in groups)
        {
            Groups.Add(group);
        }

        // Keep the selection valid; clear it if the selected record fell out of the set.
        if (_selectedId is not null && _allLogs.All(l => l.Id != _selectedId))
        {
            SelectedId = null;
        }

        OnPropertyChanged(nameof(FilteredLogs));
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(FilteredCount));
        OnPropertyChanged(nameof(CountLabel));
        OnPropertyChanged(nameof(ProviderCount));
        OnPropertyChanged(nameof(ProjectCount));
        OnPropertyChanged(nameof(SelectedLog));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
