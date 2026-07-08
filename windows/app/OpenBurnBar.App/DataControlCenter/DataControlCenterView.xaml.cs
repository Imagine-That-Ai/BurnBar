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

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The Data &amp; Privacy Control Center surface (Windows). A tier-grouped NavigationView sidebar +
/// governance toolbar + mercury Basin + sortable inventory + domain inspector, all bound to the
/// portable <see cref="DataControlCenterViewModel"/>. Until a real Firebase-backed hub is injected
/// (dev-host-deferred), the view-model runs against the signed-out hub — the surface still renders
/// the registry-seeded inventory and shows the calm "Sign in…" copy.
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

    /// <summary>
    /// Supplies the top-level window handle so the export file picker can target the app window
    /// (required for unpackaged WinUI). Set by the host that places this surface.
    /// </summary>
    public Func<IntPtr>? WindowHandleProvider { get; set; }

    /// <summary>Inject a real hub-backed view-model (e.g. the Firebase callable hub on the dev host).</summary>
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
        BuildNav();
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

    // ── View-model → UI ──────────────────────────────────────────────────────────────────────

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
            AccountPlanTier.Ultra => ("Ultra plan", ""),
            AccountPlanTier.Pro => ("Cloud Pro plan", ""),
            _ => ("Free plan", ""),
        };
    }

    // ── Navigation (tier-grouped sidebar) ────────────────────────────────────────────────────

    private void BuildNav()
    {
        DomainNav.MenuItems.Clear();
        foreach (var section in _viewModel.TierSections)
        {
            DomainNav.MenuItems.Add(new NavigationViewItemHeader { Content = TierDisplay.Label(section.Tier) });
            foreach (var row in section.Rows)
            {
                DomainNav.MenuItems.Add(new NavigationViewItem
                {
                    Content = row.Title,
                    Tag = row.Id,
                    Icon = new FontIcon
                    {
                        FontFamily = new FontFamily("Segoe MDL2 Assets"),
                        Glyph = DomainGlyphMap.Glyph(row.Id),
                        Foreground = new SolidColorBrush(TierDisplay.AccentColor(section.Tier)),
                    },
                });
            }
        }
    }

    private void OnDomainSelected(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_syncingSelection || args.SelectedItem is not NavigationViewItem { Tag: string id })
        {
            return;
        }

        Select(id, fromNav: true);
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
        foreach (var item in DomainNav.MenuItems)
        {
            if (item is NavigationViewItem { Tag: string tag } nvi && tag == id)
            {
                DomainNav.SelectedItem = nvi;
                return;
            }
        }
    }

    // ── Sort ─────────────────────────────────────────────────────────────────────────────────

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
        string chevron = descriptor.Direction == SortDirection.Ascending ? "" : "";
        SetSortGlyph(SortDomain, descriptor, SortColumn.Domain, chevron);
        SetSortGlyph(SortTier, descriptor, SortColumn.Tier, chevron);
        SetSortGlyph(SortRecords, descriptor, SortColumn.Records, chevron);
        SetSortGlyph(SortStored, descriptor, SortColumn.Stored, chevron);
        SetSortGlyph(SortRetention, descriptor, SortColumn.Retention, chevron);
    }

    private static void SetSortGlyph(FontIcon icon, SortDescriptor descriptor, SortColumn column, string chevron) =>
        icon.Glyph = descriptor.Column == column ? chevron : string.Empty;

    // ── Toolbar ──────────────────────────────────────────────────────────────────────────────

    private async void OnRefreshClick(object sender, RoutedEventArgs e) => await _viewModel.RefreshUsageAsync();

    private async void OnExportAllClick(object sender, RoutedEventArgs e) => await ExportAsync(null);

    private async void OnRecoveryClick(object sender, RoutedEventArgs e) => await ShowRecoveryDialogAsync();

    private async void OnPanicClick(object sender, RoutedEventArgs e)
    {
        var dialog = new PanicRevokeDialog(_viewModel) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
    }

    // ── Dialogs + export ─────────────────────────────────────────────────────────────────────

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
        if (json is null)
        {
            return;
        }

        if (WindowHandleProvider is null)
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
