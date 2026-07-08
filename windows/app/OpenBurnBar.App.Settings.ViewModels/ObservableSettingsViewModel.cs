// Shared INotifyPropertyChanged base for the portable Settings view-models.
//
// The rest of the Windows port hand-rolls INotifyPropertyChanged on every view-model
// (there is no CommunityToolkit.Mvvm / Prism in the tree). This base collapses the
// exact `Set<T>` + `OnPropertyChanged([CallerMemberName])` boilerplate proven by
// AgentLens' Windows peers (e.g. SwitcherSettingsViewModel) into one place so each of
// the ~11 settings tab view-models stays focused on its own state + actions +
// validation. The semantics are identical to that idiom: `Set` returns true only when
// the value actually changed, so property setters can gate derived-property fan-out.

using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Base class providing the codebase-standard <see cref="INotifyPropertyChanged"/> plumbing.</summary>
public abstract class ObservableSettingsViewModel : INotifyPropertyChanged
{
    /// <inheritdoc />
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// Assign <paramref name="value"/> to <paramref name="field"/> and raise
    /// <see cref="PropertyChanged"/> only when it actually changed. Returns whether it
    /// changed so setters can fan out to derived properties.
    /// </summary>
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(name);
        return true;
    }

    /// <summary>Raise <see cref="PropertyChanged"/> for <paramref name="name"/> (defaults to the caller).</summary>
    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
