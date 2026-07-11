using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.ElderWand;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// The Elder Wand preset lifecycle section (Windows). The save bar lowers the in-flight edit
/// (<see cref="ElderWandConfiguratorModel"/>) into a preset via the store
/// (<see cref="ElderWandSettingsModel"/>); the row list renders the portable
/// <see cref="ElderWandPresetListViewModel"/> and offers Edit / Set-as-Default / Rename / Delete.
/// All three view-models are portable + unit-tested on macOS; this control wires them to WinUI
/// controls and two ContentDialogs. The container calls <see cref="SetContext"/> once.
/// </summary>
public sealed partial class ElderWandPresetSection : UserControl
{
    public ElderWandPresetSection()
    {
        InitializeComponent();
    }

    /// <summary>The shared edit buffer (save / edit target). Set via <see cref="SetContext"/>.</summary>
    public ElderWandConfiguratorModel? Editor { get; private set; }

    /// <summary>The preset store. Set via <see cref="SetContext"/>.</summary>
    public ElderWandSettingsModel? Settings { get; private set; }

    /// <summary>The observable preset-row projection. Set via <see cref="SetContext"/>.</summary>
    public ElderWandPresetListViewModel? PresetList { get; private set; }

    /// <summary>Bind the edit buffer, store, and row projection, then refresh compiled bindings.</summary>
    public void SetContext(
        ElderWandConfiguratorModel editor,
        ElderWandSettingsModel settings,
        ElderWandPresetListViewModel presetList)
    {
        Editor = editor;
        Settings = settings;
        PresetList = presetList;
        Bindings.Update();
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (Editor is null || Settings is null)
        {
            return;
        }

        if (Editor.BuildPreset() is { } preset)
        {
            Settings.Save(preset);
            Editor.Reset();
        }
    }

    private void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (Editor is not null && Row(sender) is { } row)
        {
            Editor.Load(row.Preset);
        }
    }

    private void OnSetDefaultClick(object sender, RoutedEventArgs e)
    {
        if (Settings is not null && Row(sender) is { } row)
        {
            Settings.SetDefault(row.Id);
        }
    }

    private async void OnRenameClick(object sender, RoutedEventArgs e)
    {
        if (Settings is null || Row(sender) is not { } row)
        {
            return;
        }

        var input = new TextBox
        {
            PlaceholderText = "Preset name",
            Text = row.Name,
            SelectionStart = row.Name.Length,
        };

        var dialog = new ContentDialog
        {
            Title = "Rename Preset",
            Content = input,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            string trimmed = input.Text.Trim();
            if (trimmed.Length > 0)
            {
                Settings.Rename(row.Id, trimmed);
            }
        }
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (Settings is null || Row(sender) is not { } row)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            Title = "Delete this preset?",
            Content = $"{row.Name} will be removed. This can't be undone.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            if (Editor is not null && Editor.EditingPresetId == row.Id)
            {
                Editor.Reset();
            }

            Settings.Delete(row.Id);
        }
    }

    private static ElderWandPresetRow? Row(object sender) =>
        sender is FrameworkElement element && element.Tag is ElderWandPresetRow row ? row : null;
}
