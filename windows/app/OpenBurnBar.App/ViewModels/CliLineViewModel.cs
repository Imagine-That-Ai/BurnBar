using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Cli;

namespace OpenBurnBar.App.ViewModels;

/// <summary>
/// One rendered line in the live CLI stream. Text is mutable so a partial chunk can be
/// appended in place (a real stream arrives token-by-token), while <see cref="Kind"/> is
/// fixed at the moment the line opened and drives its color.
/// </summary>
public sealed class CliLineViewModel : INotifyPropertyChanged
{
    private string _text;

    public CliLineViewModel(CliStreamEventKind kind, string text)
    {
        Kind = kind;
        _text = text;
    }

    public CliStreamEventKind Kind { get; }

    public string Text
    {
        get => _text;
        private set
        {
            if (_text != value)
            {
                _text = value;
                OnPropertyChanged();
            }
        }
    }

    /// <summary>Append a chunk to this line (no-op for an empty chunk).</summary>
    public void Append(string chunk)
    {
        if (!string.IsNullOrEmpty(chunk))
        {
            Text = _text + chunk;
        }
    }

    /// <summary>Foreground brush resolved from the merged design-token dictionary.</summary>
    public Brush Foreground => ResolveBrush(Kind);

    private static Brush ResolveBrush(CliStreamEventKind kind)
    {
        string key = kind switch
        {
            CliStreamEventKind.Stdout => "OBBStdoutBrush",
            CliStreamEventKind.Stderr => "OBBStderrBrush",
            CliStreamEventKind.ToolCall => "OBBToolBrush",
            _ => "OBBSystemBrush",
        };

        if (Application.Current.Resources.TryGetValue(key, out object? value) && value is Brush brush)
        {
            return brush;
        }

        return new SolidColorBrush(Microsoft.UI.Colors.White);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
