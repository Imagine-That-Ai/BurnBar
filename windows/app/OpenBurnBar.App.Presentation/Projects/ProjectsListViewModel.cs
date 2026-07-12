using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// One project group derived from session metadata (list-level peer).
/// Full project-code static parse depth is WPD-0003 / F2.
/// </summary>
public sealed record ProjectListItem(string ProjectKey, int SessionCount, string Summary);

/// <summary>
/// IA-4 Projects list from usage/session source. Groups sessions by project key
/// when present; otherwise an honest empty state. Never claims static-parser depth.
/// </summary>
public sealed class ProjectsListViewModel : INotifyPropertyChanged
{
    private readonly ISessionLogReadSource _source;
    private string _status = "Loading…";
    private bool _isEmpty = true;

    public ProjectsListViewModel(ISessionLogReadSource source)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        Projects = new ObservableCollection<ProjectListItem>();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<ProjectListItem> Projects { get; }

    public string Status
    {
        get => _status;
        private set
        {
            if (_status != value)
            {
                _status = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Status)));
            }
        }
    }

    public bool IsEmpty
    {
        get => _isEmpty;
        private set
        {
            if (_isEmpty != value)
            {
                _isEmpty = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsEmpty)));
            }
        }
    }

    /// <summary>UI must disclose WPD-0003 static-parse deferral.</summary>
    public string DepthDisclosure { get; } =
        "List-level project grouping only. Full project-code static parser is deferred (WPD-0003) until revived.";

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        IReadOnlyList<SessionLogRecord> items = await _source
            .ListAsync(cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        IEnumerable<ProjectListItem> groups = items
            .GroupBy(ProjectKeyFor)
            .Select(g => new ProjectListItem(
                g.Key,
                g.Count(),
                $"{g.Count()} session(s)"))
            .OrderByDescending(p => p.SessionCount)
            .ThenBy(p => p.ProjectKey, StringComparer.OrdinalIgnoreCase);

        Projects.Clear();
        foreach (ProjectListItem project in groups)
        {
            Projects.Add(project);
        }

        IsEmpty = Projects.Count == 0;
        Status = IsEmpty
            ? "No project groups yet. Sessions without a project name appear as “Unassigned” once usage data is connected."
            : $"{Projects.Count} project group(s) — list-level peer (IA-4).";
    }

    private static string ProjectKeyFor(SessionLogRecord item)
    {
        if (string.IsNullOrWhiteSpace(item.ProjectName))
        {
            return "Unassigned";
        }

        return item.ProjectName.Trim();
    }
}
