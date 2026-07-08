using System.Collections.Generic;
using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Switcher;

namespace OpenBurnBar.App.Switcher;

/// <summary>
/// "Switch Account" destination picker. The candidate destinations come from the portable
/// <see cref="SwitcherDestinationPlanner"/>; selecting one records <see cref="SelectedDestination"/>
/// and closes the dialog so the host can open that destination's sign-in URL.
/// </summary>
public sealed partial class AccountDestinationPickerDialog : ContentDialog
{
    public AccountDestinationPickerDialog(string profileName, IReadOnlyList<AccountChangeDestination> destinations)
    {
        InitializeComponent();
        PromptText.Text = $"Choose where to log in for {profileName}.";

        var cards = new ObservableCollection<DestinationCardViewModel>();
        foreach (var destination in destinations)
        {
            cards.Add(new DestinationCardViewModel(destination));
        }

        DestinationList.ItemsSource = cards;
    }

    /// <summary>The chosen destination, or <c>null</c> if the user cancelled.</summary>
    public AccountChangeDestination? SelectedDestination { get; private set; }

    private void OnDestinationClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: DestinationCardViewModel card })
        {
            SelectedDestination = card.Destination;
            Hide();
        }
    }
}

/// <summary>Bindable card for one <see cref="AccountChangeDestination"/>.</summary>
public sealed class DestinationCardViewModel
{
    public DestinationCardViewModel(AccountChangeDestination destination)
    {
        Destination = destination;
        Label = destination.Label();
        Subtitle = destination.Subtitle();
        Glyph = destination.Glyph();
        AccentColorHex = destination.AccentColorHex();
    }

    public AccountChangeDestination Destination { get; }

    public string Label { get; }

    public string Subtitle { get; }

    public string Glyph { get; }

    public string AccentColorHex { get; }
}
