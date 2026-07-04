using System;
using System.ComponentModel;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Pet.Chat;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Pet;

/// <summary>
/// The pet speech bubble. Bind it with <see cref="Bind"/> to a
/// <see cref="PetChatBubbleViewModel"/> (which wraps the LANDED Chat state machine);
/// it renders the latest assistant text and drives sends + input-focus signals back
/// into the pet's behavior graph. Windows-gated.
/// </summary>
public sealed partial class PetChatBubbleView : UserControl
{
    private PetChatBubbleViewModel? _viewModel;

    public PetChatBubbleView()
    {
        InitializeComponent();
    }

    /// <summary>Attach the view-model (idempotent-safe: re-binding swaps handlers).</summary>
    public void Bind(PetChatBubbleViewModel viewModel)
    {
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelChanged;
        }
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        _viewModel.PropertyChanged += OnViewModelChanged;
        Render();
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e) => Render();

    private void Render()
    {
        if (_viewModel is null)
        {
            return;
        }
        TranscriptText.Text = LatestAssistantText(_viewModel);
        SendButton.IsEnabled = !_viewModel.IsSendBusy;
    }

    private static string LatestAssistantText(PetChatBubbleViewModel vm)
    {
        for (var i = vm.Messages.Count - 1; i >= 0; i--)
        {
            var m = vm.Messages[i];
            if (m.Role == ChatMessageRole.Assistant)
            {
                return m.Content;
            }
        }
        return string.Empty;
    }

    private void OnDraftFocus(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        _viewModel?.NotifyInputFocused();

    private void OnDraftBlur(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        _viewModel?.NotifyInputBlurred();

    private void OnDraftTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_viewModel is not null)
        {
            _viewModel.DraftText = DraftBox.Text;
        }
    }

    private void OnSendClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var record = _viewModel?.BeginUserTurn();
        if (record is not null)
        {
            DraftBox.Text = string.Empty;
        }
    }
}
