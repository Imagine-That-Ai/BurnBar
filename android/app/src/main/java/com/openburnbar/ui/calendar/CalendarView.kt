// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.calendar

import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.CalendarMonthSnapshot
import com.openburnbar.data.stores.CalendarSelectionSnapshot
import com.openburnbar.data.stores.CalendarStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.util.Formatting
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Locale

// MARK: - Calendar Page
//
// First-class Calendar analytics: a heat-mapped month grid on top, a
// selection-driven gallery of analytics cards below. Tap toggles a day,
// long-press then drag paints a contiguous range — the selection drives every
// card. Mirrors the macOS `CalendarView` surface.
//
// Layout persistence: `CalendarPageLayout` JSON in preferences DataStore
// (`CalendarPageLayoutStore`).
// Data: `CalendarStore` — month heat from server rollups, selection
// breakdowns re-aggregated client-side from the live usage window, so tapping
// around the grid never hits the network.

internal const val CALENDAR_GRID_COLUMNS = 7
internal const val CALENDAR_GRID_ROWS = 6

/** The 42 cell dates for [month]'s grid, starting on the locale's
 *  [firstDayOfWeek] on/before the 1st — overflow days belong to the
 *  neighboring months. Pure; unit-tested. */
internal fun monthGridDates(month: YearMonth, firstDayOfWeek: DayOfWeek): List<LocalDate> {
    val first = month.atDay(1)
    val shift = (first.dayOfWeek.value - firstDayOfWeek.value + CALENDAR_GRID_COLUMNS) % CALENDAR_GRID_COLUMNS
    val start = first.minusDays(shift.toLong())
    return List(CALENDAR_GRID_COLUMNS * CALENDAR_GRID_ROWS) { start.plusDays(it.toLong()) }
}

/** Locale-ordered single-letter weekday labels (S M T W T F S in en_US). */
internal fun weekdayLabels(firstDayOfWeek: DayOfWeek, locale: Locale): List<String> = (0 until CALENDAR_GRID_COLUMNS).map {
    val day = DayOfWeek.of(((firstDayOfWeek.value - 1 + it) % CALENDAR_GRID_COLUMNS) + 1)
    day.getDisplayName(TextStyle.NARROW, locale)
}

/** Screen state bundle, mirrors the `PulseViewScaffoldState` pattern. */
internal data class CalendarScreenState(
    val layout: CalendarPageLayout,
    val visibleMonth: YearMonth,
    val selectedDays: Set<LocalDate>,
    val monthSnapshot: CalendarMonthSnapshot,
    val selectionSnapshot: CalendarSelectionSnapshot,
    val isLoading: Boolean,
    val editing: Boolean,
    val today: LocalDate,
)

/** Gesture/edit handler bundle for [CalendarScaffold]. */
internal data class CalendarScreenHandlers(
    val onToggleEditing: () -> Unit,
    val onShowCard: (CalendarCardKind) -> Unit,
    val onResetLayout: () -> Unit,
    val onShiftMonth: (Long) -> Unit,
    val onToday: () -> Unit,
    val onTapDay: (LocalDate) -> Unit,
    val onRangeStart: (LocalDate) -> Unit,
    val onRangeUpdate: (LocalDate) -> Unit,
    val onRangeEnd: () -> Unit,
    val onMoveCard: (CalendarCardKind, Int) -> Unit,
    val onHideCard: (CalendarCardKind) -> Unit,
    val onCycleSpan: (CalendarCardKind) -> Unit,
)

@Composable
fun CalendarView(store: CalendarStore = viewModel(), userStore: UserStore = viewModel()) {
    val context = LocalContext.current
    val layoutStore = remember(context) { CalendarPageLayoutStore.get(context) }
    val layout by layoutStore.layout.collectAsState()
    val currentUser by userStore.user.collectAsState()

    DisposableEffect(currentUser.isSignedIn) {
        if (currentUser.isSignedIn) store.startListening()
        onDispose { store.stopListening() }
    }

    val visibleMonth by store.visibleMonth.collectAsState()
    val selectedDays by store.selectedDays.collectAsState()
    val monthSnapshot by store.monthSnapshot.collectAsState()
    val selectionSnapshot by store.selectionSnapshot.collectAsState()
    val isLoading by store.isLoading.collectAsState()

    // Gesture-state owner: tap/long-press-drag verbs live here; the resulting
    // day set is mirrored into the store, which owns aggregation.
    val selectionModel = remember { CalendarSelectionModel() }
    val applySelection: () -> Unit = { store.setSelection(selectionModel.selectedDays) }

    // Default selection: today (mirrors the macOS onAppear behavior).
    LaunchedEffect(Unit) {
        if (store.selectedDays.value.isEmpty()) {
            selectionModel.select(store.today())
            applySelection()
        }
    }

    var editing by remember { mutableStateOf(false) }
    val today = store.today()

    CalendarScaffold(
        state =
        CalendarScreenState(
            layout = layout,
            visibleMonth = visibleMonth,
            selectedDays = selectedDays,
            monthSnapshot = monthSnapshot,
            selectionSnapshot = selectionSnapshot,
            isLoading = isLoading,
            editing = editing,
            today = today,
        ),
        handlers =
        CalendarScreenHandlers(
            onToggleEditing = { editing = !editing },
            onShowCard = { kind -> layoutStore.persist(layout.setVisible(kind, true)) },
            onResetLayout = { layoutStore.persist(layout.reset()) },
            onShiftMonth = { delta -> store.shiftMonth(delta) },
            onToday = {
                store.setVisibleMonth(YearMonth.from(today))
                selectionModel.select(today)
                applySelection()
            },
            onTapDay = { day ->
                selectionModel.toggle(day)
                applySelection()
            },
            onRangeStart = { day ->
                selectionModel.beginDrag(day)
                applySelection()
            },
            onRangeUpdate = { day ->
                selectionModel.updateDrag(day)
                applySelection()
            },
            onRangeEnd = { selectionModel.endDrag() },
            onMoveCard = { kind, delta -> layoutStore.persist(layout.move(kind, delta)) },
            onHideCard = { kind -> layoutStore.persist(layout.setVisible(kind, false)) },
            onCycleSpan = { kind ->
                val current = layout.configs.firstOrNull { it.kind == kind } ?: return@CalendarScreenHandlers
                layoutStore.persist(layout.setSpan(kind, current.span.next()))
            },
        ),
    )
}

@Composable
internal fun CalendarScaffold(state: CalendarScreenState, handlers: CalendarScreenHandlers) {
    Box(modifier = Modifier.fillMaxSize()) {
        CalendarTitleBar(state = state, handlers = handlers)
        CalendarScrollContent(state = state, handlers = handlers)
    }
}

@Composable
private fun CalendarScrollContent(state: CalendarScreenState, handlers: CalendarScreenHandlers) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 128.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp),
    ) {
        Spacer(modifier = Modifier.height(64.dp))

        CalendarMonthCard(state = state, handlers = handlers)

        CalendarPanelSection(
            selectionSnapshot = state.selectionSnapshot,
            selectionEmpty = state.selectedDays.isEmpty(),
            layout = state.layout,
            editing = state.editing,
            onMove = handlers.onMoveCard,
            onHide = handlers.onHideCard,
            onCycleSpan = handlers.onCycleSpan,
        )
    }
}

// MARK: - Title bar

@Composable
private fun CalendarTitleBar(state: CalendarScreenState, handlers: CalendarScreenHandlers) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.LG.dp)
            .padding(top = AuroraSpacing.MD.dp, bottom = AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Calendar",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onBackground,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = selectionSubtitle(state.selectionSnapshot),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.6f),
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        CalendarEditMenu(state = state, handlers = handlers)
    }
}

@Composable
private fun CalendarEditMenu(state: CalendarScreenState, handlers: CalendarScreenHandlers) {
    Box {
        IconButton(onClick = handlers.onToggleEditing) {
            Icon(
                imageVector = Icons.Filled.Tune,
                contentDescription = "Edit cards",
                tint =
                if (state.editing) {
                    AuroraColors.teal
                } else {
                    MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f)
                },
            )
        }
        DropdownMenu(expanded = state.editing, onDismissRequest = handlers.onToggleEditing) {
            state.layout.hiddenConfigs.forEach { config ->
                DropdownMenuItem(
                    text = { Text("Show ${config.kind.title}") },
                    onClick = { handlers.onShowCard(config.kind) },
                )
            }
            DropdownMenuItem(
                text = { Text("Reset Layout") },
                onClick = {
                    handlers.onResetLayout()
                    handlers.onToggleEditing()
                },
            )
            DropdownMenuItem(
                text = { Text("Done") },
                onClick = handlers.onToggleEditing,
            )
        }
    }
}

private fun selectionSubtitle(snapshot: CalendarSelectionSnapshot): String {
    val days = snapshot.selectedDays
    if (days.isEmpty()) return "Tap days to analyze — long-press and drag paints a range."
    val locale = Locale.getDefault()
    val summary =
        if (days.size == 1) {
            days.first().format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(locale))
        } else {
            val short = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale)
            "${days.first().format(short)} – ${days.last().format(short)} · ${days.size} days"
        }
    if (snapshot.isEmpty) return summary
    return "$summary · ${Formatting.formatCurrency(snapshot.totalCost)} · " +
        "${Formatting.formatTokens(snapshot.totalTokens)} tokens · ${snapshot.sessionCount} sessions"
}

// MARK: - Month card

@Composable
private fun CalendarMonthCard(state: CalendarScreenState, handlers: CalendarScreenHandlers) {
    AuroraGlassCard(
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.LG.dp),
        contentPadding = AuroraSpacing.MD.dp,
    ) {
        val locale = Locale.getDefault()
        val firstDayOfWeek = WeekFields.of(locale).firstDayOfWeek
        val gridDates = remember(state.visibleMonth, firstDayOfWeek) { monthGridDates(state.visibleMonth, firstDayOfWeek) }

        CalendarMonthHeader(state = state, handlers = handlers)
        Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
        CalendarWeekdayHeader(firstDayOfWeek = firstDayOfWeek, locale = locale)
        Spacer(modifier = Modifier.height(AuroraSpacing.XS.dp))
        CalendarDayGrid(state = state, handlers = handlers, gridDates = gridDates)

        if (state.isLoading && state.monthSnapshot.dayCosts.isEmpty()) {
            Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
            Text(
                text = "Loading your month…",
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun CalendarMonthHeader(state: CalendarScreenState, handlers: CalendarScreenHandlers) {
    val locale = Locale.getDefault()
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = state.visibleMonth.format(DateTimeFormatter.ofPattern("MMMM yyyy", locale)),
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (state.monthSnapshot.monthTotalCost > 0.0) {
                Text(
                    text = "${Formatting.formatCurrency(state.monthSnapshot.monthTotalCost)} this month",
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                )
            }
        }
        IconButton(onClick = { handlers.onShiftMonth(-1) }, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Filled.ChevronLeft, contentDescription = "Previous month", tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f))
        }
        TextButton(onClick = handlers.onToday, modifier = Modifier.height(32.dp)) {
            Text("Today", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f))
        }
        IconButton(onClick = { handlers.onShiftMonth(1) }, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Filled.ChevronRight, contentDescription = "Next month", tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun CalendarWeekdayHeader(firstDayOfWeek: DayOfWeek, locale: Locale) {
    val labels = remember(firstDayOfWeek, locale) { weekdayLabels(firstDayOfWeek, locale) }
    Row(modifier = Modifier.fillMaxWidth()) {
        labels.forEach { label ->
            Text(
                text = label,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
            )
        }
    }
}

@Composable
private fun CalendarDayGrid(state: CalendarScreenState, handlers: CalendarScreenHandlers, gridDates: List<LocalDate>) {
    // Tap + long-press-drag resolved from grid coordinates.
    var gridSize by remember { mutableStateOf(IntSize.Zero) }
    val dateAt: (Offset) -> LocalDate? = gridDateResolver(gridDates) { gridSize }
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .onSizeChanged { gridSize = it }
            .pointerInput(gridDates) {
                detectTapGestures(
                    onTap = { offset -> dateAt(offset)?.let(handlers.onTapDay) },
                )
            }
            .pointerInput(gridDates) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { offset -> dateAt(offset)?.let(handlers.onRangeStart) },
                    onDragEnd = handlers.onRangeEnd,
                    onDragCancel = handlers.onRangeEnd,
                    onDrag = { change, _ -> dateAt(change.position)?.let(handlers.onRangeUpdate) },
                )
            },
    ) {
        repeat(CALENDAR_GRID_ROWS) { row ->
            Row(modifier = Modifier.fillMaxWidth()) {
                repeat(CALENDAR_GRID_COLUMNS) { column ->
                    val day = gridDates[row * CALENDAR_GRID_COLUMNS + column]
                    CalendarDayCell(
                        day = day,
                        isCurrentMonth = YearMonth.from(day) == state.visibleMonth,
                        isToday = day == state.today,
                        isSelected = state.selectedDays.contains(day),
                        heat = state.monthSnapshot.heat(day),
                        providers = state.monthSnapshot.dayProviders[day].orEmpty(),
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

/**
 * Maps a pixel offset inside the grid to its cell date. Grid cells are square:
 * width ÷ 7 columns, height ÷ 6 rows. Pure (aside from the [gridSize] read);
 * unit-tested through the same math.
 */
internal fun gridDateResolver(dates: List<LocalDate>, gridSize: () -> IntSize): (Offset) -> LocalDate? = { offset ->
    val size = gridSize()
    if (size.width <= 0 || size.height <= 0 || dates.size < CALENDAR_GRID_COLUMNS * CALENDAR_GRID_ROWS) {
        null
    } else {
        val column = (offset.x / (size.width / CALENDAR_GRID_COLUMNS.toFloat())).toInt()
        val row = (offset.y / (size.height / CALENDAR_GRID_ROWS.toFloat())).toInt()
        if (column in 0 until CALENDAR_GRID_COLUMNS && row in 0 until CALENDAR_GRID_ROWS) {
            dates[row * CALENDAR_GRID_COLUMNS + column]
        } else {
            null
        }
    }
}

// MARK: - Panel section (states + cards)

@Composable
private fun CalendarPanelSection(
    selectionSnapshot: CalendarSelectionSnapshot,
    selectionEmpty: Boolean,
    layout: CalendarPageLayout,
    editing: Boolean,
    onMove: (CalendarCardKind, Int) -> Unit,
    onHide: (CalendarCardKind) -> Unit,
    onCycleSpan: (CalendarCardKind) -> Unit,
) {
    when {
        selectionEmpty -> CalendarHintState(
            title = "Select days to analyze",
            detail = "Tap a day, tap more days to build a multi-selection, or long-press and drag across the grid.",
        )
        selectionSnapshot.isEmpty -> CalendarHintState(
            title = "No usage on these days",
            detail = "Run an agent or pick busier days — the cards draw themselves from every request you make.",
        )
        else -> CalendarAnalyticsPanel(
            layout = layout,
            snapshot = selectionSnapshot,
            editing = editing,
            onMove = onMove,
            onHide = onHide,
            onCycleSpan = onCycleSpan,
        )
    }
}

@Composable
private fun CalendarHintState(title: String, detail: String) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.LG.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Text(
            text = title,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = detail,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
            textAlign = TextAlign.Center,
        )
    }
}
