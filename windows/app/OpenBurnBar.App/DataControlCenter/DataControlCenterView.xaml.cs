using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.UI;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// Data &amp; Privacy Control Center (Windows) — layout lockstep with macOS
/// <c>DataControlCenterView</c>: domain sidebar + plan footer, detail toolbar,
/// Basin above inventory table, trailing inspector.
/// </summary>
public sealed partial class DataControlCenterView : UserControl
{
    private DataControlCenterViewModel _viewModel = new();
    private bool _syncingSelection;

    public DataControlCenterView()
    {
        InitializeComponent();
        BindViewModel();
        Inspector.ExportRequested += async (_, row) => await ExportAsync(new[] { row.Id });
        Inspector.RecoverRequested += async (_, _) => await ShowRecoveryDialogAsync();
        Inspector.DeleteRequested += async (_, row) => await ShowDeleteDialogAsync(row);
        Loaded += OnLoaded;
    }

    public Func<IntPtr>? WindowHandleProvider { get; set; }

    public void SetViewModel(DataControlCenterViewModel viewModel)
    {
        _viewModel.PropertyChanged -= OnViewModelChanged;
        _viewModel = viewModel;
        BindViewModel();
        RenderState();
    }

    private void BindViewModel()
    {
        _viewModel.PropertyChanged += OnViewModelChanged;
        BuildDomainSidebar();
        RefreshInventory();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await _viewModel.RefreshUsageAsync();
        if (_viewModel.SelectedId is null && DataDomains.All.Count > 0)
        {
            Select(DataDomains.All[0].Id);
        }
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(DataControlCenterViewModel.SortedRows):
                RefreshInventory();
                break;
            case nameof(DataControlCenterViewModel.SealedFraction):
            case nameof(DataControlCenterViewModel.BasinCaption):
                UpdateBasin();
                break;
            case nameof(DataControlCenterViewModel.Rows):
            case nameof(DataControlCenterViewModel.Tier):
                RenderState();
                break;
            case nameof(DataControlCenterViewModel.UsageError):
                UpdateErrorBanner();
                break;
            case nameof(DataControlCenterViewModel.IsLoadingUsage):
                UpdateRefreshSpinner();
                break;
        }
    }

    private void RenderState()
    {
        BuildDomainSidebar();
        RefreshInventory();
        UpdateBasin();
        UpdateErrorBanner();
        UpdatePlanSummary();
    }

    private void RefreshInventory()
    {
        InventoryList.ItemsSource = _viewModel.SortedRows;
        UpdateSortGlyphs();
    }

    private void UpdateBasin()
    {
        Basin.Fill = _viewModel.SealedFraction;
        Basin.Caption = _viewModel.BasinCaption;
    }

    private void UpdateErrorBanner()
    {
        if (_viewModel.HasUsageError)
        {
            ErrorText.Text = _viewModel.UsageError;
            ErrorBanner.Visibility = Visibility.Visible;
        }
        else
        {
            ErrorBanner.Visibility = Visibility.Collapsed;
        }
    }

    private void UpdateRefreshSpinner()
    {
        bool loading = _viewModel.IsLoadingUsage;
        RefreshSpinner.IsActive = loading;
        RefreshSpinner.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        RefreshGlyph.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
        RefreshButton.IsEnabled = !loading;
    }

    private void UpdatePlanSummary()
    {
        (PlanSummary.Text, PlanGlyph.Glyph) = _viewModel.Tier switch
        {
            AccountPlanTier.Ultra => ("Ultra plan", "\uE7B6"),
            AccountPlanTier.Pro => ("Cloud Pro plan", "\uE946"),
            _ => ("Free plan", "\uE753"),
        };
    }

    // ── Domain sidebar (tier sections) ────────────────────────────────────────

    private void BuildDomainSidebar() =>
        RebuildDomainSidebarAsElements(_viewModel.SelectedId);

    private void RebuildDomainSidebarAsElements(string? selectedId)
    {
        DomainList.Items.Clear();
        DomainList.ItemTemplate = null;
        DomainList.ItemTemplateSelector = null;

        foreach (var section in _viewModel.TierSections)
        {
            Color accent = TierDisplay.AccentColor(section.Tier);
            var header = new TextBlock
            {
                Text = TierDisplay.Label(section.Tier).ToUpperInvariant(),
                FontSize = 10,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                CharacterSpacing = 100,
                Foreground = new SolidColorBrush(accent),
                Margin = new Thickness(8, 12, 8, 4),
                IsHitTestVisible = false,
            };
            DomainList.Items.Add(header);

            foreach (var row in section.Rows)
            {
                var rowPanel = new Grid { Tag = row.Id, ColumnSpacing = 10 };
                rowPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                rowPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

                var icon = new FontIcon
                {
                    FontFamily = new FontFamily("Segoe MDL2 Assets"),
                    Glyph = DomainGlyphMap.Glyph(row.Id),
                    FontSize = 13,
                    Foreground = new SolidColorBrush(accent),
                    VerticalAlignment = VerticalAlignment.Center,
                    Width = 20,
                };
                Grid.SetColumn(icon, 0);

                var textStack = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
                textStack.Children.Add(new TextBlock
                {
                    Text = row.Title,
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                    Foreground = (Brush)Application.Current.Resources["PensieveColorTextBaseBrush"],
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
                if (row.HasRecords)
                {
                    textStack.Children.Add(new TextBlock
                    {
                        Text = $"{row.Count} records",
                        FontSize = 10,
                        Foreground = (Brush)Application.Current.Resources["PensieveColorTextMuteBrush"],
                    });
                }

                Grid.SetColumn(textStack, 1);
                rowPanel.Children.Add(icon);
                rowPanel.Children.Add(textStack);
                DomainList.Items.Add(rowPanel);

                if (selectedId == row.Id)
                {
                    DomainList.SelectedItem = rowPanel;
                }
            }
        }
    }

    private void OnDomainListSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        if (DomainList.SelectedItem is FrameworkElement { Tag: string id })
        {
            Select(id, fromNav: true);
        }
        else if (DomainList.SelectedItem is TextBlock)
        {
            // Header selected — reselect previous domain row
            if (_viewModel.SelectedId is { } keep)
            {
                SelectNavItem(keep);
            }
        }
    }

    private void OnInventorySelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection || InventoryList.SelectedItem is not DomainRow row)
        {
            return;
        }

        Select(row.Id, fromInventory: true);
    }

    private void Select(string id, bool fromNav = false, bool fromInventory = false)
    {
        _viewModel.SelectedId = id;
        _syncingSelection = true;
        try
        {
            if (!fromNav)
            {
                SelectNavItem(id);
            }

            if (!fromInventory)
            {
                InventoryList.SelectedItem = _viewModel.Row(id);
            }
        }
        finally
        {
            _syncingSelection = false;
        }

        if (_viewModel.Row(id) is { } selected)
        {
            Inspector.Show(_viewModel, selected);
            Inspector.Visibility = Visibility.Visible;
            EmptyInspector.Visibility = Visibility.Collapsed;
        }
    }

    private void SelectNavItem(string id)
    {
        foreach (var item in DomainList.Items)
        {
            if (item is FrameworkElement { Tag: string tag } fe && tag == id)
            {
                DomainList.SelectedItem = fe;
                return;
            }
        }
    }

    private void OnSortHeaderClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tag } && Enum.TryParse<SortColumn>(tag, out var column))
        {
            _viewModel.ApplySort(column);
        }
    }

    private void UpdateSortGlyphs()
    {
        var descriptor = _viewModel.SortDescriptor;
        string chevron = descriptor.Direction == SortDirection.Ascending ? "\uE70E" : "\uE70D";
        SetSortGlyph(SortDomain, descriptor, SortColumn.Domain, chevron);
        SetSortGlyph(SortTier, descriptor, SortColumn.Tier, chevron);
        SetSortGlyph(SortRecords, descriptor, SortColumn.Records, chevron);
        SetSortGlyph(SortStored, descriptor, SortColumn.Stored, chevron);
        SetSortGlyph(SortRetention, descriptor, SortColumn.Retention, chevron);
    }

    private static void SetSortGlyph(FontIcon icon, SortDescriptor descriptor, SortColumn column, string chevron) =>
        icon.Glyph = descriptor.Column == column ? chevron : string.Empty;

    private async void OnRefreshClick(object sender, RoutedEventArgs e) => await _viewModel.RefreshUsageAsync();

    private async void OnExportAllClick(object sender, RoutedEventArgs e) => await ExportAsync(null);

    private async void OnRecoveryClick(object sender, RoutedEventArgs e) => await ShowRecoveryDialogAsync();

    private async void OnPanicClick(object sender, RoutedEventArgs e)
    {
        var dialog = new PanicRevokeDialog(_viewModel) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
    }

    private async Task ShowRecoveryDialogAsync()
    {
        var dialog = new RecoverySetupDialog(_viewModel) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
    }

    private async Task ShowDeleteDialogAsync(DomainRow row)
    {
        var dialog = new DeleteDomainDialog(_viewModel, row.Domain) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
    }

    private async Task ExportAsync(IReadOnlyList<string>? domains)
    {
        string? json = await _viewModel.ExportDataAsync(domains);
        if (json is null || WindowHandleProvider is null)
        {
            return;
        }

        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = domains is { Count: 1 } ? $"burnbar-{domains[0]}-export" : "burnbar-data-export",
        };
        picker.FileTypeChoices.Add("JSON", new List<string> { ".json" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandleProvider());

        StorageFile? file = await picker.PickSaveFileAsync();
        if (file is null)
        {
            return;
        }

        try
        {
            await FileIO.WriteTextAsync(file, json);
        }
        catch (Exception error)
        {
            _viewModel.SetExportWriteError(error);
            UpdateErrorBanner();
        }
    }
}

