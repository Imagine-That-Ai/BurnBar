using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Presentation.Calendar;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;
using Windows.UI;

namespace OpenBurnBar.App.Calendar;

/// <summary>
/// Calendar analytics surface — Windows peer of macOS
/// <c>AgentLens/Views/Calendar/CalendarView.swift</c>. A heat-mapped month grid
/// on the left, a selection-driven gallery of analytics cards on the right.
/// Click selects a day, Shift-click extends a contiguous range, Ctrl-click
/// toggles days (the Windows peer of ⌘-click), and dragging paints a range.
/// Cards are hideable/reorderable (drag onto another card)/resizable (S·M·L
/// spans via context menu); the layout persists through
/// <see cref="CalendarLayoutStore"/>. All aggregation is prepared by the
/// portable <c>OpenBurnBar.App.Presentation.Calendar</c> layer; this page
/// renders snapshots only. Load failures surface as a typed error state —
/// never as a legitimate empty month.
/// </summary>
public sealed partial class CalendarPage : Page
{
    private const double CellHeight = 46;
    private const double HeatmapCell = 12;

    private readonly TimeZoneInfo _timeZone = TimeZoneInfo.Local;
    private readonly CalendarSelectionModel _selection = new();
    private readonly CalendarLayoutStore _layoutStore;
    private CalendarPageLayout _layout;
    private CalendarMonthGridModel _grid;
    private DateOnly _visibleMonth;
    private CalendarUsageData _usage = CalendarUsageData.Empty;
    private CalendarMonthSnapshot? _monthSnapshot;
    private CalendarSelectionSnapshot? _selectionSnapshot;
    private int _loadGeneration;
    private bool _loaded;

    // Pointer-gesture state (click vs drag disambiguation, macOS minimumDistance: 3).
    private bool _pointerCaptured;
    private bool _pointerDragging;
    private DateOnly _pressDay;
    private double _pressX;
    private double _pressY;
    private bool _pressShift;
    private bool _pressCtrl;

    public CalendarPage()
    {
        _layoutStore = new CalendarLayoutStore(WindowsSettingsComposition.SharedPersistence);
        _layout = _layoutStore.Load();
        _visibleMonth = CalendarLocalTime.Today(_timeZone);
        _grid = CalendarMonthGridModel.Create(_visibleMonth, CultureInfo.CurrentCulture);

        InitializeComponent();

        if (_selection.IsEmpty)
        {
            _selection.Select(CalendarLocalTime.Today(_timeZone));
        }

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    // MARK: Lifecycle

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_loaded)
        {
            return;
        }

        _loaded = true;
        if (App.Current.UsageRuntime is { } runtime)
        {
            runtime.StateChanged += OnUsageRuntimeStateChanged;
        }

        await LoadMonthAsync().ConfigureAwait(true);
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (App.Current.UsageRuntime is { } runtime)
        {
            runtime.StateChanged -= OnUsageRuntimeStateChanged;
        }

        _loaded = false;
    }

    private async void OnUsageRuntimeStateChanged(object sender, UsageRuntimeStateChangedEventArgs args)
    {
        // A completed scan persists to SQLCipher before publishing; re-read the window.
        if (args.Current.Phase is UsageRuntimePhase.Ready
            or UsageRuntimePhase.Degraded
            or UsageRuntimePhase.NoData)
        {
            await LoadMonthAsync().ConfigureAwait(true);
        }
    }

    // MARK: Data flow

    private async System.Threading.Tasks.Task LoadMonthAsync()
    {
        int generation = Interlocked.Increment(ref _loadGeneration);
        ShowLoadingState();

        DateTimeOffset startUtc = CalendarLocalTime.DayStartUtc(_grid.GridStart, _timeZone);
        DateTimeOffset endUtc = CalendarLocalTime.DayStartUtc(_grid.GridEndExclusive, _timeZone);
        try
        {
            CalendarUsageData data = await CalendarUsageProvider
                .LoadAsync(startUtc, endUtc, _visibleMonth)
                .ConfigureAwait(true);
            if (generation != _loadGeneration)
            {
                return; // A newer navigation superseded this load.
            }

            _usage = data;
            _monthSnapshot = CalendarMonthSnapshot.Build(data.Rows, _grid, _timeZone);
            RebuildSelection();
            RenderAll();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            AppDiagnostics.LogException("calendar.load", ex);
            if (generation != _loadGeneration)
            {
                return;
            }

            ShowState(
                "\uE7BA",
                "Usage data could not be loaded",
                ex is CalendarUsageDataException
                    ? "Encrypted usage storage returned a corrupt row. Open Diagnostics for details."
                    : "The usage store is unavailable. Open Data & Privacy settings or Diagnostics for details.");
        }
    }

    /// <summary>Re-aggregates the already-loaded month rows for the current selection (no reload — every click is database-free).</summary>
    private void RebuildSelection()
    {
        _selectionSnapshot = CalendarSelectionSnapshot.Build(
            _usage.Rows,
            _selection.SelectedDays,
            _timeZone);
    }

    // MARK: Rendering

    private void RenderAll()
    {
        RenderHeader();
        RenderMonthCard();
        RenderPanel();
    }

    private void RenderHeader()
    {
        if (_selection.IsEmpty)
        {
            HeaderSubtitle.Text = "Pick a day — Shift extends a range, Ctrl toggles days, drag paints.";
        }
        else
        {
            string summary = SelectionSummaryText();
            HeaderSubtitle.Text = _selectionSnapshot is { IsEmpty: false } snapshot
                ? $"{summary} · {CalendarFormatting.Cost(snapshot.TotalCost)} · "
                    + $"{CalendarFormatting.Tokens(snapshot.TotalTokens)} tokens · {snapshot.SessionCount} sessions"
                : summary;
        }

        switch (_usage.Origin)
        {
            case DashboardUsageOrigin.Sample:
                OriginChipText.Text = "Sample data preview";
                OriginChip.Visibility = Visibility.Visible;
                break;
            case DashboardUsageOrigin.Cloud:
                OriginChipText.Text = "Synced from your cloud";
                OriginChip.Visibility = Visibility.Visible;
                break;
            default:
                OriginChip.Visibility = Visibility.Collapsed;
                break;
        }

        EditCardsButton.Flyout = BuildEditCardsMenu();
    }

    private string SelectionSummaryText()
    {
        IReadOnlyList<DateOnly> days = _selection.OrderedDays;
        if (days.Count == 0)
        {
            return "No days selected";
        }

        DateOnly first = days[0];
        DateOnly last = days[^1];
        CultureInfo culture = CultureInfo.CurrentCulture;
        if (first == last)
        {
            return first.ToDateTime(TimeOnly.MinValue).ToString("D", culture);
        }

        return $"{first.ToDateTime(TimeOnly.MinValue):d} – {last.ToDateTime(TimeOnly.MinValue):d} · {days.Count} days";
    }

    private void RenderMonthCard()
    {
        CultureInfo culture = CultureInfo.CurrentCulture;
        MonthLabel.Text = _grid.MonthStart.ToDateTime(TimeOnly.MinValue).ToString("MMMM yyyy", culture);
        MonthTotalLabel.Text = _monthSnapshot is { MonthTotalCost: > 0 } snapshot
            ? $"{CalendarFormatting.Cost(snapshot.MonthTotalCost)} this month"
            : string.Empty;

        RenderWeekdayHeader(culture);
        RenderCells();
    }

    private void RenderWeekdayHeader(CultureInfo culture)
    {
        WeekdayHeaderGrid.Children.Clear();
        WeekdayHeaderGrid.ColumnDefinitions.Clear();
        WeekdayHeaderGrid.RowDefinitions.Clear();
        WeekdayHeaderGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (int column = 0; column < 7; column++)
        {
            WeekdayHeaderGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var label = new TextBlock
            {
                Text = _grid.WeekdaySymbols[column].ToUpper(culture),
                FontSize = 9,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center,
                Foreground = BrushOf("AuroraTextMutedBrush"),
            };
            Grid.SetColumn(label, column);
            WeekdayHeaderGrid.Children.Add(label);
        }
    }

    private void RenderCells()
    {
        CellsHostGrid.Children.Clear();
        var rows = new StackPanel();
        CellsHostGrid.Children.Add(rows);

        DateOnly today = CalendarLocalTime.Today(_timeZone);
        SolidColorBrush accent = BrushOf("AuroraAccentBrush");
        for (int week = 0; week < _grid.Weeks.Count; week++)
        {
            var rowGrid = new Grid();
            if (week < _grid.Weeks.Count - 1)
            {
                rowGrid.Margin = new Thickness(0, 0, 0, CalendarMonthGridModel.CellSpacing);
            }

            for (int column = 0; column < 7; column++)
            {
                rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            }

            IReadOnlyList<DateOnly> days = _grid.Weeks[week];
            for (int column = 0; column < days.Count; column++)
            {
                Border cell = BuildCell(days[column], today, accent);
                if (column < 6)
                {
                    cell.Margin = new Thickness(0, 0, CalendarMonthGridModel.CellSpacing, 0);
                }

                Grid.SetColumn(cell, column);
                rowGrid.Children.Add(cell);
            }

            rows.Children.Add(rowGrid);
        }
    }

    private Border BuildCell(DateOnly day, DateOnly today, SolidColorBrush accent)
    {
        double cost = _monthSnapshot?.CostFor(day) ?? 0;
        bool isSelected = _selection.IsSelected(day);
        bool isToday = day == today;
        bool isInMonth = _grid.IsInMonth(day);
        bool isDark = ActualTheme == ElementTheme.Dark;

        Brush fill;
        Brush ring;
        if (isSelected)
        {
            fill = WithOpacity(accent, CalendarHeatmap.SelectedFillOpacity(isDark));
            ring = WithOpacity(accent, CalendarHeatmap.SelectedRingOpacity);
        }
        else if (cost > 0 && (_monthSnapshot?.PeakDayCost ?? 0) > 0)
        {
            fill = WithOpacity(accent, CalendarHeatmap.FillOpacity(cost, _monthSnapshot!.PeakDayCost));
            ring = isToday
                ? WithOpacity(accent, CalendarHeatmap.TodayRingOpacity)
                : WithOpacity(BrushOf("AuroraGlassStrokeBrush"), CalendarHeatmap.RestingRingOpacity);
        }
        else
        {
            fill = WithOpacity(BrushOf("AuroraSurfaceBrush"), isDark ? 0.4 : 0.5);
            ring = isToday
                ? WithOpacity(accent, CalendarHeatmap.TodayRingOpacity)
                : WithOpacity(BrushOf("AuroraGlassStrokeBrush"), CalendarHeatmap.RestingRingOpacity);
        }

        var numberLabel = new TextBlock
        {
            Text = day.Day.ToString(CultureInfo.InvariantCulture),
            FontSize = 11,
            FontWeight = isToday ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Medium,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(5, 4, 0, 0),
            Foreground = !isInMonth
                ? BrushOf("AuroraTextMutedBrush")
                : isToday ? accent : BrushOf("AuroraTextBrush"),
        };

        var content = new Grid();
        content.Children.Add(numberLabel);
        if (cost > 0)
        {
            content.Children.Add(new TextBlock
            {
                Text = CalendarFormatting.Cost(cost),
                FontSize = 8,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 5, 5, 0),
                Foreground = BrushOf("AuroraTextMutedBrush"),
            });
        }

        IReadOnlyList<string> providers = _monthSnapshot?.ProvidersFor(day) ?? Array.Empty<string>();
        if (providers.Count > 0)
        {
            var dots = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(5, 0, 0, 4),
            };
            foreach (string provider in providers.Take(CalendarMonthSnapshot.MaxDayProviders))
            {
                dots.Children.Add(new Ellipse
                {
                    Width = 4,
                    Height = 4,
                    Margin = new Thickness(0, 0, 2.5, 0),
                    Fill = new SolidColorBrush(ProviderColor(provider)),
                });
            }

            content.Children.Add(dots);
        }

        var cell = new Border
        {
            Height = CellHeight,
            CornerRadius = new CornerRadius(7),
            Background = fill,
            BorderBrush = ring,
            BorderThickness = new Thickness(isSelected ? 1.5 : 1),
            Opacity = isInMonth ? 1 : CalendarHeatmap.OutOfMonthOpacity,
            Child = content,
        };
        ToolTipService.SetToolTip(cell, CellToolTip(day, cost, isToday));
        AutomationProperties.SetName(cell, CellToolTip(day, cost, isToday));
        return cell;
    }

    private static string CellToolTip(DateOnly day, double cost, bool isToday)
    {
        string text = day.ToDateTime(TimeOnly.MinValue).ToString("D", CultureInfo.CurrentCulture);
        if (cost > 0)
        {
            text += ", " + CalendarFormatting.Cost(cost);
        }

        if (isToday)
        {
            text += ", Today";
        }

        return text;
    }

    // MARK: Pointer gestures (click with modifiers + drag-to-range)

    private void OnCellsPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Windows.Foundation.Point point = e.GetCurrentPoint(CellsHostGrid).Position;
        if (DayAt(point.X, point.Y) is not { } day)
        {
            return;
        }

        _pointerCaptured = CellsHostGrid.CapturePointer(e.Pointer);
        _pointerDragging = false;
        _pressDay = day;
        _pressX = point.X;
        _pressY = point.Y;
        _pressShift = IsKeyDown(VirtualKey.Shift);
        _pressCtrl = IsKeyDown(VirtualKey.Control);
        e.Handled = true;
    }

    private void OnCellsPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_pointerCaptured)
        {
            return;
        }

        Windows.Foundation.Point point = e.GetCurrentPoint(CellsHostGrid).Position;
        if (!_pointerDragging)
        {
            double dx = point.X - _pressX;
            double dy = point.Y - _pressY;
            if ((dx * dx) + (dy * dy) < 9) // macOS DragGesture(minimumDistance: 3)
            {
                return;
            }

            _pointerDragging = true;
            _selection.BeginDrag(_pressDay);
        }

        if (DayAt(point.X, point.Y) is { } day)
        {
            _selection.UpdateDrag(day);
        }

        OnSelectionChanged();
        e.Handled = true;
    }

    private void OnCellsPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_pointerCaptured)
        {
            return;
        }

        if (_pointerDragging)
        {
            _selection.EndDrag();
        }
        else if (_pressCtrl)
        {
            _selection.Toggle(_pressDay);
        }
        else if (_pressShift)
        {
            _selection.ExtendTo(_pressDay);
        }
        else
        {
            _selection.Select(_pressDay);
        }

        ReleasePointerCapture(e);
        OnSelectionChanged();
        e.Handled = true;
    }

    private void OnCellsPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_pointerDragging)
        {
            _selection.EndDrag();
            OnSelectionChanged();
        }

        ReleasePointerCapture(e);
    }

    private void ReleasePointerCapture(PointerRoutedEventArgs e)
    {
        _pointerCaptured = false;
        _pointerDragging = false;
        CellsHostGrid.ReleasePointerCapture(e.Pointer);
    }

    private DateOnly? DayAt(double x, double y)
    {
        int? index = CalendarMonthGridModel.DayIndexAt(
            x,
            y,
            CellsHostGrid.ActualWidth,
            _grid.Weeks.Count,
            CellHeight,
            CalendarMonthGridModel.CellSpacing);
        IReadOnlyList<DateOnly> allDays = _grid.AllDays;
        return index is { } i && i >= 0 && i < allDays.Count ? allDays[i] : null;
    }

    private static bool IsKeyDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    // MARK: Selection + navigation

    private void OnSelectionChanged()
    {
        RebuildSelection();
        RenderHeader();
        RenderCells();
        RenderPanel();
    }

    private async void OnPrevMonth(object sender, RoutedEventArgs e) => await ShiftMonthAsync(-1);

    private async void OnNextMonth(object sender, RoutedEventArgs e) => await ShiftMonthAsync(1);

    private async void OnToday(object sender, RoutedEventArgs e)
    {
        _visibleMonth = CalendarLocalTime.Today(_timeZone);
        _grid = CalendarMonthGridModel.Create(_visibleMonth, CultureInfo.CurrentCulture);
        _selection.Select(CalendarLocalTime.Today(_timeZone));
        await LoadMonthAsync().ConfigureAwait(true);
    }

    private async System.Threading.Tasks.Task ShiftMonthAsync(int delta)
    {
        _visibleMonth = _grid.MonthStart.AddMonths(delta);
        _grid = _grid.Advanced(delta);
        await LoadMonthAsync().ConfigureAwait(true);
    }

    // MARK: Analytics panel

    private void RenderPanel()
    {
        if (_selection.IsEmpty)
        {
            ShowState(
                "\uE787",
                "Select days to analyze",
                "Click a day, Shift-click to extend a range, Ctrl-click to toggle days, or drag across the grid.");
            return;
        }

        if (_selectionSnapshot is null)
        {
            ShowLoadingState();
            return;
        }

        if (_selectionSnapshot.IsEmpty)
        {
            ShowState(
                "\uE787",
                "No usage on these days",
                _usage.Origin == DashboardUsageOrigin.Empty
                    ? OpenBurnBar.App.Configuration.RuntimeDataMode.EmptyStateDetail("a provider")
                    : "Run an agent or pick busier days — the cards draw themselves from every request you make.");
            return;
        }

        StateHost.Visibility = Visibility.Collapsed;
        CardsScroller.Visibility = Visibility.Visible;
        RenderCards();
    }

    private void ShowLoadingState() =>
        ShowState("\uE917", "Loading your month…", string.Empty);

    private void ShowState(string glyph, string title, string detail)
    {
        CardsScroller.Visibility = Visibility.Collapsed;
        StateHost.Visibility = Visibility.Visible;
        StateGlyph.Glyph = glyph;
        StateTitle.Text = title;
        StateDetail.Text = detail;
        StateDetail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RenderCards()
    {
        CardsHost.Children.Clear();
        foreach (CalendarPageLayout.Row row in CalendarPageLayout.PackRows(_layout.VisibleConfigs))
        {
            var rowGrid = new Grid { ColumnSpacing = 12 };
            for (int i = 0; i < 3; i++)
            {
                rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            }

            int column = 0;
            foreach (CalendarCardConfig config in row.Configs)
            {
                int span = Math.Min(3, Math.Max(1, config.Span));
                FrameworkElement card = BuildCard(config);
                Grid.SetColumn(card, column);
                Grid.SetColumnSpan(card, span);
                rowGrid.Children.Add(card);
                column += span;
            }

            CardsHost.Children.Add(rowGrid);
        }
    }

    private FrameworkElement BuildCard(CalendarCardConfig config)
    {
        CalendarCardKind kind = config.Kind;
        var body = new StackPanel { Spacing = 8 };

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var glyph = new FontIcon
        {
            Glyph = CalendarCardKindMetadata.Glyph(kind),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = BrushOf("AuroraAccentBrush"),
        };
        var title = new TextBlock
        {
            Text = CalendarCardKindMetadata.Title(kind),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 0, 0),
            Foreground = BrushOf("AuroraTextBrush"),
        };
        Grid.SetColumn(title, 1);
        header.Children.Add(glyph);
        header.Children.Add(title);
        body.Children.Add(header);

        body.Children.Add(BuildCardContent(kind));

        body.Children.Add(new TextBlock
        {
            Text = CalendarCardKindMetadata.WhyItMatters(kind),
            FontSize = 10,
            TextWrapping = TextWrapping.Wrap,
            Foreground = BrushOf("AuroraTextMutedBrush"),
        });

        var card = new Border
        {
            Style = (Style)Application.Current.Resources["AuroraGlassCardStyle"],
            Child = body,
            CanDrag = true,
            AllowDrop = true,
        };
        card.ContextFlyout = BuildCardMenu(config);
        card.DragStarting += (s, e) =>
        {
            e.Data.SetText(CalendarCardKindMetadata.Id(kind));
            e.Data.RequestedOperation = DataPackageOperation.Move;
        };
        card.DragOver += (s, e) =>
        {
            e.AcceptedOperation = DataPackageOperation.Move;
            e.DragUIOverride.Caption = "Reorder card";
        };
        card.Drop += async (s, e) =>
        {
            Windows.Foundation.Deferral deferral = e.GetDeferral();
            try
            {
                if (e.DataView.Contains(StandardDataFormats.Text)
                    && await e.DataView.GetTextAsync() is string dropped
                    && CalendarCardKindMetadata.KindForId(dropped) is { } dragged
                    && dragged != kind)
                {
                    _layout.Move(dragged, kind);
                    PersistLayout();
                }
            }
            finally
            {
                deferral.Complete();
            }
        };
        AutomationProperties.SetName(card, CalendarCardKindMetadata.Title(kind));
        return card;
    }

    private MenuFlyout BuildCardMenu(CalendarCardConfig config)
    {
        var menu = new MenuFlyout();
        var sizeMenu = new MenuFlyoutSubItem { Text = "Size" };
        foreach ((int span, string label) in new[] { (1, "S"), (2, "M"), (3, "L") })
        {
            var item = new ToggleMenuFlyoutItem
            {
                Text = label,
                IsChecked = config.Span == span,
            };
            int captured = span;
            item.Click += (s, e) =>
            {
                _layout.SetSpan(config.Kind, captured);
                PersistLayout();
            };
            sizeMenu.Items.Add(item);
        }

        menu.Items.Add(sizeMenu);
        var hide = new MenuFlyoutItem { Text = "Hide Card" };
        hide.Click += (s, e) =>
        {
            _layout.SetVisible(config.Kind, false);
            PersistLayout();
        };
        menu.Items.Add(hide);
        return menu;
    }

    private MenuFlyout BuildEditCardsMenu()
    {
        var menu = new MenuFlyout();
        foreach (CalendarCardConfig hidden in _layout.HiddenConfigs)
        {
            var item = new MenuFlyoutItem
            {
                Text = CalendarCardKindMetadata.Title(hidden.Kind),
                Icon = new FontIcon { Glyph = CalendarCardKindMetadata.Glyph(hidden.Kind), FontSize = 12 },
            };
            item.Click += (s, e) =>
            {
                _layout.SetVisible(hidden.Kind, true);
                PersistLayout();
            };
            menu.Items.Add(item);
        }

        if (menu.Items.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        var reset = new MenuFlyoutItem { Text = "Reset Layout" };
        reset.Click += (s, e) =>
        {
            _layout.Reset();
            PersistLayout();
        };
        menu.Items.Add(reset);
        return menu;
    }

    private void PersistLayout()
    {
        _layoutStore.Save(_layout);
        RenderHeader();
        RenderCards();
    }

    // MARK: Card contents

    private FrameworkElement BuildCardContent(CalendarCardKind kind)
    {
        CalendarSelectionSnapshot snapshot = _selectionSnapshot!;
        return kind switch
        {
            CalendarCardKind.Kpis => BuildKpis(snapshot),
            CalendarCardKind.BurnOverSelection => BuildBurnBars(snapshot),
            CalendarCardKind.ProviderMix => BuildProviderMix(snapshot),
            CalendarCardKind.ModelMix => BuildModelMix(snapshot),
            CalendarCardKind.HourOfDayHeatmap => BuildHourHeatmap(snapshot),
            CalendarCardKind.ProjectFocus => BuildProjectFocus(snapshot),
            CalendarCardKind.CacheRoi => BuildCacheTiles(snapshot),
            CalendarCardKind.ReasoningShare => BuildReasoningTiles(snapshot),
            _ => new Grid(),
        };
    }

    private FrameworkElement BuildKpis(CalendarSelectionSnapshot snapshot)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        (string Label, string Value)[] tiles =
        {
            ("Cost", CalendarFormatting.Cost(snapshot.TotalCost)),
            ("Tokens", CalendarFormatting.Tokens(snapshot.TotalTokens)),
            ("Sessions", snapshot.SessionCount.ToString(CultureInfo.InvariantCulture)),
            ("Active Days", snapshot.ActiveDays.ToString(CultureInfo.InvariantCulture)),
            ("Avg Cost/Day", CalendarFormatting.Cost(snapshot.AverageCostPerDay)),
        };
        for (int i = 0; i < tiles.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            FrameworkElement tile = StatTile(tiles[i].Label, tiles[i].Value);
            Grid.SetColumn(tile, i);
            grid.Children.Add(tile);
        }

        return grid;
    }

    private FrameworkElement BuildBurnBars(CalendarSelectionSnapshot snapshot)
    {
        double max = snapshot.DailyBurn.Count == 0 ? 0 : snapshot.DailyBurn.Max(bucket => bucket.Value);
        var grid = new Grid { ColumnSpacing = 3, Height = 150 };
        for (int i = 0; i < snapshot.DailyBurn.Count; i++)
        {
            CalendarDateBucket bucket = snapshot.DailyBurn[i];
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            double height = max > 0 ? Math.Max(2, 140 * (bucket.Value / max)) : 0;
            var bar = new Border
            {
                Height = height,
                VerticalAlignment = VerticalAlignment.Bottom,
                CornerRadius = new CornerRadius(2),
                Background = BrushOf("AuroraAccentBrush"),
            };
            ToolTipService.SetToolTip(bar, $"{bucket.Day.ToDateTime(TimeOnly.MinValue):d} · {CalendarFormatting.Cost(bucket.Value)}");
            Grid.SetColumn(bar, i);
            grid.Children.Add(bar);
        }

        return grid;
    }

    private FrameworkElement BuildProviderMix(CalendarSelectionSnapshot snapshot)
    {
        double total = snapshot.ProviderShares.Sum(share => share.Cost);
        var panel = new StackPanel { Spacing = 8 };
        foreach (CalendarSelectionSnapshot.ProviderShare share in snapshot.ProviderShares)
        {
            double fraction = total > 0 ? share.Cost / total : 0;
            var line = new Grid { ColumnSpacing = 8 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var logo = new ProviderLogoView
            {
                Provider = ProviderBrandOf(share.Provider),
                LogoSize = 14,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var name = new TextBlock
            {
                Text = share.Provider,
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = BrushOf("AuroraTextBrush"),
            };
            var pct = new TextBlock
            {
                Text = CalendarFormatting.Percent(fraction),
                FontSize = 10,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = BrushOf("AuroraTextMutedBrush"),
            };
            var cost = new TextBlock
            {
                Text = CalendarFormatting.Cost(share.Cost),
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 0, 0),
                Foreground = BrushOf("AuroraTextBrush"),
            };
            Grid.SetColumn(name, 1);
            Grid.SetColumn(pct, 2);
            Grid.SetColumn(cost, 3);
            line.Children.Add(logo);
            line.Children.Add(name);
            line.Children.Add(pct);
            line.Children.Add(cost);

            var row = new StackPanel { Spacing = 3 };
            row.Children.Add(line);
            row.Children.Add(ShareBar(fraction));
            panel.Children.Add(row);
        }

        return panel;
    }

    private FrameworkElement BuildModelMix(CalendarSelectionSnapshot snapshot)
    {
        double total = snapshot.TopModels.Sum(model => model.Cost);
        var panel = new StackPanel { Spacing = 8 };
        foreach (CalendarSelectionSnapshot.ModelCost model in snapshot.TopModels)
        {
            double fraction = total > 0 ? model.Cost / total : 0;
            var line = new Grid { ColumnSpacing = 8 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new Ellipse
            {
                Width = 8,
                Height = 8,
                VerticalAlignment = VerticalAlignment.Center,
                Fill = new SolidColorBrush(ProviderBrand.ColorForModelBrush(model.Model)),
            });
            var name = new TextBlock
            {
                Text = model.DisplayName,
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = BrushOf("AuroraTextBrush"),
            };
            var cost = new TextBlock
            {
                Text = CalendarFormatting.Cost(model.Cost),
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = BrushOf("AuroraTextBrush"),
            };
            Grid.SetColumn(name, 1);
            Grid.SetColumn(cost, 2);
            line.Children.Add(name);
            line.Children.Add(cost);

            var row = new StackPanel { Spacing = 3 };
            row.Children.Add(line);
            row.Children.Add(ShareBar(fraction));
            panel.Children.Add(row);
        }

        return panel;
    }

    private FrameworkElement BuildProjectFocus(CalendarSelectionSnapshot snapshot)
    {
        double total = snapshot.ProjectShares.Sum(project => project.Cost);
        var panel = new StackPanel { Spacing = 8 };
        foreach (CalendarSelectionSnapshot.ProjectCost project in snapshot.ProjectShares)
        {
            double fraction = total > 0 ? project.Cost / total : 0;
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = new TextBlock
            {
                Text = project.Name,
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = BrushOf("AuroraTextBrush"),
            };
            var cost = new TextBlock
            {
                Text = CalendarFormatting.Cost(project.Cost),
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = BrushOf("AuroraTextBrush"),
            };
            Grid.SetColumn(cost, 1);
            line.Children.Add(name);
            line.Children.Add(cost);

            var row = new StackPanel { Spacing = 3 };
            row.Children.Add(line);
            row.Children.Add(ShareBar(fraction));
            panel.Children.Add(row);
        }

        return panel;
    }

    private FrameworkElement BuildHourHeatmap(CalendarSelectionSnapshot snapshot)
    {
        double peak = 0;
        foreach (double[] weekday in snapshot.HourWeekdayCost)
        {
            foreach (double value in weekday)
            {
                peak = Math.Max(peak, value);
            }
        }

        string[] weekdayLabels = { "S", "M", "T", "W", "T", "F", "S" };
        SolidColorBrush accent = BrushOf("AuroraAccentBrush");
        var panel = new StackPanel { Spacing = 3 };
        for (int weekday = 0; weekday < 7; weekday++)
        {
            var row = new Grid { ColumnSpacing = 2 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
            for (int hour = 0; hour < 24; hour++)
            {
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            }

            var label = new TextBlock
            {
                Text = weekdayLabels[weekday],
                FontSize = 9,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = BrushOf("AuroraTextMutedBrush"),
            };
            row.Children.Add(label);
            for (int hour = 0; hour < 24; hour++)
            {
                double value = snapshot.HourWeekdayCost[weekday][hour];
                double opacity = CalendarHeatmap.FillOpacity(value, peak);
                var cell = new Border
                {
                    Height = HeatmapCell,
                    CornerRadius = new CornerRadius(2),
                    Background = opacity > 0
                        ? WithOpacity(accent, opacity)
                        : WithOpacity(BrushOf("AuroraSurfaceBrush"), 0.4),
                };
                if (value > 0)
                {
                    ToolTipService.SetToolTip(
                        cell,
                        $"{CultureInfo.CurrentCulture.DateTimeFormat.AbbreviatedDayNames[weekday]} {hour}:00 · {CalendarFormatting.Cost(value)}");
                }

                Grid.SetColumn(cell, hour + 1);
                row.Children.Add(cell);
            }

            panel.Children.Add(row);
        }

        if (snapshot.PeakWeekdayIndex is { } peakWeekday && snapshot.PeakHour is { } peakHour)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"Peak: {CultureInfo.CurrentCulture.DateTimeFormat.DayNames[peakWeekday]}s around {peakHour}:00",
                FontSize = 10,
                Foreground = BrushOf("AuroraTextMutedBrush"),
            });
        }

        return panel;
    }

    private FrameworkElement BuildCacheTiles(CalendarSelectionSnapshot snapshot)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        (string Label, string Value)[] tiles =
        {
            ("Cache Hit Rate", CalendarFormatting.Percent(snapshot.CacheHitRate)),
            ("Cache Read Tokens", CalendarFormatting.Tokens(snapshot.CacheReadTokens)),
            ("Savings (est.)", CalendarFormatting.Cost(snapshot.CacheSavingsEstimate)),
        };
        for (int i = 0; i < tiles.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            FrameworkElement tile = StatTile(tiles[i].Label, tiles[i].Value);
            Grid.SetColumn(tile, i);
            grid.Children.Add(tile);
        }

        return grid;
    }

    private FrameworkElement BuildReasoningTiles(CalendarSelectionSnapshot snapshot)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        (string Label, string Value)[] tiles =
        {
            ("Reasoning Share", CalendarFormatting.Percent(snapshot.ReasoningShare)),
            ("Reasoning Tokens", CalendarFormatting.Tokens(snapshot.ReasoningTokens)),
        };
        for (int i = 0; i < tiles.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            FrameworkElement tile = StatTile(tiles[i].Label, tiles[i].Value);
            Grid.SetColumn(tile, i);
            grid.Children.Add(tile);
        }

        return grid;
    }

    // MARK: Small builders + brushes

    private FrameworkElement StatTile(string label, string value)
    {
        return new StackPanel
        {
            Children =
            {
                new TextBlock
                {
                    Text = label.ToUpper(CultureInfo.CurrentCulture),
                    FontSize = 9,
                    Foreground = BrushOf("AuroraTextMutedBrush"),
                },
                new TextBlock
                {
                    Text = value,
                    FontSize = 16,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Margin = new Thickness(0, 2, 0, 0),
                    Foreground = BrushOf("AuroraTextBrush"),
                },
            },
        };
    }

    private FrameworkElement ShareBar(double fraction)
    {
        double clamped = Math.Min(1, Math.Max(0, fraction));
        var grid = new Grid { Height = 3 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(clamped, 0.001), GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(1 - clamped, 0.001), GridUnitType.Star) });
        var filled = new Border
        {
            CornerRadius = new CornerRadius(1.5),
            Background = BrushOf("AuroraAccentBrush"),
        };
        var rest = new Border
        {
            CornerRadius = new CornerRadius(1.5),
            Background = WithOpacity(BrushOf("AuroraSurfaceBrush"), 0.5),
        };
        Grid.SetColumn(rest, 1);
        grid.Children.Add(filled);
        grid.Children.Add(rest);
        return grid;
    }

    private SolidColorBrush BrushOf(string key) =>
        (SolidColorBrush)Application.Current.Resources[key];

    private static SolidColorBrush WithOpacity(SolidColorBrush brush, double opacity)
    {
        Color color = brush.Color;
        return new SolidColorBrush(Color.FromArgb(
            (byte)Math.Round(color.A * Math.Min(1, Math.Max(0, opacity))),
            color.R,
            color.G,
            color.B));
    }

    private static Color ProviderColor(string providerDisplayName) =>
        ProviderBrand.Primary(ProviderBrandOf(providerDisplayName));

    /// <summary>
    /// Reverse lookup of a usage provider id (the macOS <c>AgentProvider.rawValue</c>
    /// display name, e.g. "Claude Code") to the shared brand enum via
    /// <see cref="ProviderMetadata.DisplayName"/> — no duplicated tables; unknown
    /// providers fall back to the OpenBurnBar brand mark.
    /// </summary>
    private static AgentProviderBrand ProviderBrandOf(string providerDisplayName)
    {
        foreach (AgentProviderBrand brand in Enum.GetValues<AgentProviderBrand>())
        {
            if (string.Equals(
                    ProviderMetadata.DisplayName(brand),
                    providerDisplayName,
                    StringComparison.OrdinalIgnoreCase))
            {
                return brand;
            }
        }

        return AgentProviderBrand.OpenBurnBar;
    }
}
