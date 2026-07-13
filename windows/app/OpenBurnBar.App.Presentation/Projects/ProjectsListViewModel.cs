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
/// One project group derived from session metadata. Code-symbol depth is loaded
/// separately when the signed Tree-sitter parser is available.
/// </summary>
public sealed record ProjectListItem(string ProjectKey, int SessionCount, string Summary);

/// <summary>
/// IA-4 Projects list from usage/session source plus an optional bounded code
/// symbol index. Missing parser/root configuration remains an explicit fallback.
/// </summary>
public sealed class ProjectsListViewModel : INotifyPropertyChanged
{
    private readonly ISessionLogReadSource _source;
    private readonly ProjectCodeSymbolIndex? _codeIndex;
    private readonly IProjectCodeStaticParserClient? _parser;
    private string _status = "Loading…";
    private bool _isEmpty = true;
    private string _depthDisclosure =
        "List-level project grouping only. Configure OPENBURNBAR_PROJECT_ROOT for code symbols.";

    public ProjectsListViewModel(
        ISessionLogReadSource source,
        ProjectCodeSymbolIndex? codeIndex = null,
        IProjectCodeStaticParserClient? parser = null)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        _codeIndex = codeIndex;
        _parser = parser;
        Projects = new ObservableCollection<ProjectListItem>();
        CodeSymbols = new ObservableCollection<ProjectCodeSymbol>();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<ProjectListItem> Projects { get; }

    public ObservableCollection<ProjectCodeSymbol> CodeSymbols { get; }

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

    public string DepthDisclosure
    {
        get => _depthDisclosure;
        private set
        {
            if (_depthDisclosure != value)
            {
                _depthDisclosure = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DepthDisclosure)));
            }
        }
    }

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        IReadOnlyList<SessionLogRecord> items = await _source
            .ListAsync(cancellationToken: cancellationToken);

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

        await LoadCodeSymbolsAsync(cancellationToken);
    }

    private async Task LoadCodeSymbolsAsync(CancellationToken cancellationToken)
    {
        CodeSymbols.Clear();
        if (_codeIndex is null)
        {
            DepthDisclosure =
                "List-level project grouping only. Configure OPENBURNBAR_PROJECT_ROOT for code symbols (WPD-0003).";
            return;
        }

        ProjectCodeIndexSnapshot snapshot;
        if (_parser is not null)
        {
            snapshot = await _codeIndex
                .RefreshWithParserAsync(_parser, cancellationToken);
        }
        else
        {
            snapshot = await Task.Run(_codeIndex.Refresh, cancellationToken);
        }

        foreach (ProjectCodeSymbol symbol in snapshot.Symbols)
        {
            CodeSymbols.Add(symbol);
        }

        DepthDisclosure = snapshot.ParserMode == "tree-sitter"
            ? $"{CodeSymbols.Count} Tree-sitter symbol(s) indexed with blob-integrity checks."
            : $"{CodeSymbols.Count} lexical symbol(s) indexed. Full Tree-sitter parser is unavailable (WPD-0003 fallback).";
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
