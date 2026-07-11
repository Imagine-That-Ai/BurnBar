using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.Presentation.Database;

/// <summary>
/// IA-2 Database System-mode peer: browse tracked sessions via the same
/// <see cref="ISessionLogReadSource"/> SQLCipher seam as Session Logs.
/// Empty when unconfigured — never fabricates demo sessions.
/// </summary>
public sealed class DatabaseBrowseViewModel : INotifyPropertyChanged
{
    private readonly ISessionLogReadSource _source;
    private string _status = "Loading…";
    private bool _isEmpty = true;

    public DatabaseBrowseViewModel(ISessionLogReadSource source)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        Sessions = new ObservableCollection<SessionLogRecord>();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<SessionLogRecord> Sessions { get; }

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

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        IReadOnlyList<SessionLogRecord> items = await _source
            .ListAsync(cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        Sessions.Clear();
        foreach (SessionLogRecord item in items.OrderByDescending(i => i.TimelineDate))
        {
            Sessions.Add(item);
        }

        IsEmpty = Sessions.Count == 0;
        Status = IsEmpty
            ? "No tracked sessions yet. Connect the SQLCipher usage database in Settings → Data Sources, or open Session Logs after first ingest."
            : $"{Sessions.Count} tracked session(s) — Database System mode (IA-2). Story/Atlas modes are later depth.";
    }
}
