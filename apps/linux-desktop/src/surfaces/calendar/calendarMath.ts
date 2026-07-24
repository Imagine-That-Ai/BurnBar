/**
 * Calendar surface math — view-free port of the macOS Calendar lane:
 * - `CalendarMonthGridModel` (month grid, weekday header, fetch window)
 * - `CalendarSelectionModel` (click / ⇧-click / ⌘-click / drag semantics)
 * - `CalendarMonthSnapshot` + `CalendarSelectionSnapshot` (aggregations)
 * - `CalendarPageLayout` (card registry + JSON persistence contract)
 *
 * Days are keyed by LOCAL start-of-day epoch ms. All day stepping uses
 * calendar arithmetic (`new Date(y, m, d + n)`), never `+86_400_000`, so
 * DST 23/25-hour days stay aligned exactly like `Calendar.date(byAdding:)`.
 * Cross-midnight sessions attribute to the day their start lands in.
 */

import type { UsageCalendarEvent } from '../../tauriBridge.js';

// ─────────────────────────── Day primitives ───────────────────────────

/**
 * The instant a usage row is attributed to, matching the macOS oracle: the
 * call's START time.
 *
 * `recordedAt` is stamped when the completed call is logged, so it behaves as
 * an end time — bucketing by it puts a call running 23:50→00:20 on the wrong
 * day. `startTime` carries the real start where the daemon knows it; it is
 * absent on rows written before the field existed and on paths with no honest
 * start instant, where we fall back to the old behaviour rather than invent a
 * value.
 */
export function attributionInstant(event: UsageCalendarEvent): Date {
  if (event.startTime) {
    const started = new Date(event.startTime);
    if (Number.isFinite(started.getTime())) return started;
  }
  return new Date(event.recordedAt);
}

/** Local start-of-day for any date/timestamp, as epoch ms (the day key). */
export function startOfDayLocal(date: Date | number): number {
  const d = new Date(date);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

/** Add `n` calendar days to a day key (DST-safe calendar arithmetic). */
export function addDaysLocal(dayMs: number, n: number): number {
  const d = new Date(dayMs);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n).getTime();
}

/** Add `n` calendar months to a day key, clamped to start-of-day. */
export function addMonthsLocal(dayMs: number, n: number): number {
  const d = new Date(dayMs);
  return new Date(d.getFullYear(), d.getMonth() + n, 1).getTime();
}

/** First day (start-of-day key) of the month containing `date`. */
export function monthStartLocal(date: Date | number): number {
  const d = new Date(date);
  return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
}

/** Start-of-day key of the month after the one containing `monthDayMs`. */
export function nextMonthStartLocal(monthDayMs: number): number {
  return addMonthsLocal(monthStartLocal(monthDayMs), 1);
}

// ─────────────────────────── Month grid ───────────────────────────

export type MonthGrid = {
  /** First day of the visible month (day key). */
  monthStart: number;
  /** First displayed cell — up to 6 days into the previous month. */
  gridStart: number;
  /** Day key of the day AFTER the last displayed cell (exclusive grid end). */
  gridEnd: number;
  /** Displayed day keys, row-major, 7 per week, 4–6 weeks. */
  weeks: number[][];
  /** Weekday abbreviations ordered for the locale's first weekday. */
  weekdaySymbols: string[];
  /** All displayed days flattened (index = drag cell index). */
  allDays: number[];
};

/**
 * Locale first weekday as a JS `getDay()` index (0 = Sunday). Reads
 * `Intl.Locale.weekInfo` when the runtime exposes it; falls back to Sunday,
 * matching `Calendar.current.firstWeekday` for en-US.
 */
export function localeFirstWeekday(locale?: string): number {
  try {
    const loc = new Intl.Locale(locale ?? navigator.language);
    const info = (loc as unknown as { weekInfo?: { firstDay?: number } }).weekInfo;
    // Unicode firstDay: 1 = Monday … 7 = Sunday → JS: 0 = Sunday … 6 = Saturday.
    if (info?.firstDay && info.firstDay >= 1 && info.firstDay <= 7) {
      return info.firstDay % 7;
    }
  } catch {
    // Older runtimes without weekInfo — fall through to the Sunday default.
  }
  return 0;
}

/** Weekday abbreviations in grid order (locale-aware, rotated by firstWeekday). */
export function weekdaySymbolsFor(locale: string | undefined, firstWeekday: number): string[] {
  const fmt = new Intl.DateTimeFormat(locale, { weekday: 'narrow' });
  const symbols: string[] = [];
  // 2024-01-07 is a Sunday; +i walks getDay() 0…6 regardless of timezone.
  for (let i = 0; i < 7; i++) {
    symbols.push(fmt.format(new Date(2024, 0, 7 + i)));
  }
  return [...symbols.slice(firstWeekday), ...symbols.slice(0, firstWeekday)];
}

/** The month grid containing `month` (any date inside the month). */
export function monthGridFor(
  month: Date | number,
  options?: { firstWeekday?: number; locale?: string }
): MonthGrid {
  const firstWeekday = options?.firstWeekday ?? localeFirstWeekday(options?.locale);
  const monthStart = monthStartLocal(month);
  const monthWeekday = new Date(monthStart).getDay();
  const leading = (monthWeekday - firstWeekday + 7) % 7;
  const gridStart = addDaysLocal(monthStart, -leading);

  const monthDate = new Date(monthStart);
  const daysInMonth = new Date(monthDate.getFullYear(), monthDate.getMonth() + 1, 0).getDate();
  const cellCount = Math.ceil((leading + daysInMonth) / 7) * 7;

  const allDays: number[] = [];
  let cursor = gridStart;
  for (let i = 0; i < cellCount; i++) {
    allDays.push(cursor);
    cursor = addDaysLocal(cursor, 1);
  }
  const weeks: number[][] = [];
  for (let i = 0; i < allDays.length; i += 7) {
    weeks.push(allDays.slice(i, i + 7));
  }
  return {
    monthStart,
    gridStart,
    gridEnd: addDaysLocal(allDays[allDays.length - 1] ?? gridStart, 1),
    weeks,
    weekdaySymbols: weekdaySymbolsFor(options?.locale, firstWeekday),
    allDays
  };
}

/** Long month + year label for the grid header, per locale. */
export function monthLabel(monthDayMs: number, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' }).format(
    new Date(monthDayMs)
  );
}

// ─────────────────────────── Month snapshot ───────────────────────────

export type MonthSnapshot = {
  /** Total cost per local day (only days with usage appear). */
  dayCosts: Map<number, number>;
  /** Up to three provider ids per day, ranked by that day's cost. */
  dayProviders: Map<number, string[]>;
  /** The month's busiest day cost — heatmap intensity denominator. */
  peakDayCost: number;
  /** Spend on days inside the calendar month itself (overflow excluded). */
  monthTotalCost: number;
};

/** Mirror of CalendarMonthSnapshot.build: bucket rows by local start-of-day. */
export function monthSnapshotFor(events: UsageCalendarEvent[], grid: MonthGrid): MonthSnapshot {
  const dayCosts = new Map<number, number>();
  const providerCosts = new Map<number, Map<string, number>>();
  for (const event of events) {
    const at = attributionInstant(event).getTime();
    if (!Number.isFinite(at)) continue;
    const day = startOfDayLocal(at);
    if (day < grid.gridStart || day >= grid.gridEnd) continue;
    dayCosts.set(day, (dayCosts.get(day) ?? 0) + event.costUsd);
    const perProvider = providerCosts.get(day) ?? new Map<string, number>();
    perProvider.set(event.providerId, (perProvider.get(event.providerId) ?? 0) + event.costUsd);
    providerCosts.set(day, perProvider);
  }

  const dayProviders = new Map<number, string[]>();
  for (const [day, costs] of providerCosts) {
    dayProviders.set(
      day,
      [...costs.entries()]
        .sort((a, b) => (a[1] === b[1] ? (a[0] < b[0] ? -1 : 1) : b[1] - a[1]))
        .slice(0, 3)
        .map(([id]) => id)
    );
  }

  const monthEnd = nextMonthStartLocal(grid.monthStart);
  let monthTotalCost = 0;
  let peakDayCost = 0;
  for (const [day, cost] of dayCosts) {
    if (cost > peakDayCost) peakDayCost = cost;
    if (day >= grid.monthStart && day < monthEnd) monthTotalCost += cost;
  }

  return { dayCosts, dayProviders, peakDayCost, monthTotalCost };
}

/**
 * Heatmap fill opacity — sqrt keeps mid-range days visible instead of letting
 * one monster day wash the rest out (CalendarDayCell.fillColor recipe).
 */
export function heatOpacity(cost: number, peak: number): number {
  if (cost <= 0 || peak <= 0) return 0;
  return 0.1 + 0.55 * Math.sqrt(cost / peak);
}

/**
 * Hour-of-day heatmap fill. Same sqrt shape as the month grid but a wider
 * ramp, matching `ChartKitHeatmap.fill(for:peak:)` (0.14 → 0.92) — the hour
 * matrix is denser than the month grid and needs the extra contrast.
 */
export function hourHeatOpacity(value: number, peak: number): number {
  if (value <= 0 || peak <= 0) return 0;
  return 0.14 + 0.78 * Math.sqrt(value / peak);
}

// ─────────────────────────── Selection model ───────────────────────────

/**
 * Finder/Photos multi-select semantics, mirroring CalendarSelectionModel:
 * plain click selects one day and moves the anchor; ⇧-click replaces the
 * selection with the contiguous anchor…day range; ⌘/Ctrl-click toggles a
 * single day; drag paints a contiguous range from the drag's starting day.
 */
export type CalendarSelection = {
  /** Selected day keys (local start-of-day). */
  selected: Set<number>;
  /** The day range gestures extend from; survives gesture end. */
  anchor: number | null;
  /** Anchor captured when the current drag began; null outside a drag. */
  dragAnchor: number | null;
  isDragging: boolean;
};

export function emptyCalendarSelection(): CalendarSelection {
  return { selected: new Set(), anchor: null, dragAnchor: null, isDragging: false };
}

/** Every local calendar day from a to b inclusive, either direction. */
export function contiguousDays(a: number, b: number): Set<number> {
  const start = startOfDayLocal(Math.min(a, b));
  const end = startOfDayLocal(Math.max(a, b));
  const days = new Set<number>([start]);
  let cursor = start;
  // Paranoia guard against a malformed pair, mirroring the macOS cap.
  while (cursor < end && days.size < 372) {
    cursor = addDaysLocal(cursor, 1);
    days.add(cursor);
  }
  return days;
}

export function selectionSelect(sel: CalendarSelection, day: number): CalendarSelection {
  const d = startOfDayLocal(day);
  return { selected: new Set([d]), anchor: d, dragAnchor: null, isDragging: false };
}

export function selectionToggle(sel: CalendarSelection, day: number): CalendarSelection {
  const d = startOfDayLocal(day);
  const selected = new Set(sel.selected);
  if (selected.has(d)) selected.delete(d);
  else selected.add(d);
  return { ...sel, selected, anchor: d };
}

export function selectionExtend(sel: CalendarSelection, day: number): CalendarSelection {
  const d = startOfDayLocal(day);
  if (sel.anchor === null) return selectionSelect(sel, d);
  return { ...sel, selected: contiguousDays(sel.anchor, d) };
}

export function selectionBeginDrag(sel: CalendarSelection, day: number): CalendarSelection {
  const d = startOfDayLocal(day);
  return { selected: new Set([d]), anchor: d, dragAnchor: d, isDragging: true };
}

export function selectionUpdateDrag(sel: CalendarSelection, day: number): CalendarSelection {
  if (!sel.isDragging || sel.dragAnchor === null) return sel;
  return { ...sel, selected: contiguousDays(sel.dragAnchor, startOfDayLocal(day)) };
}

export function selectionEndDrag(sel: CalendarSelection): CalendarSelection {
  return { ...sel, isDragging: false, dragAnchor: null };
}

// ─────────────────────────── Selection snapshot ───────────────────────────

export type DailyBurnBucket = { day: number; label: string; costUsd: number };
export type ProviderShare = { id: string; costUsd: number };
export type ModelCost = { model: string; costUsd: number };
export type ProjectCost = { name: string; costUsd: number };

export type SelectionSnapshot = {
  selectedDays: number[];
  isEmpty: boolean;
  totalCost: number;
  totalTokens: number;
  sessionCount: number;
  activeDays: number;
  averageCostPerDay: number;
  /** Per-day cost across the selection span, gap-filled. */
  dailyBurn: DailyBurnBucket[];
  providerShares: ProviderShare[];
  topModels: ModelCost[];
  projectShares: ProjectCost[];
  /** 7×24 cost matrix; row 0 = Sunday (Gregorian weekday order). */
  hourWeekdayCost: number[][];
  peakWeekdayIndex: number | null;
  peakHour: number | null;
  cacheHitRate: number;
  cacheReadTokens: number;
  /** Cache reads billed at ~10% of the blended per-token rate ("(est.)"). */
  cacheSavingsEstimate: number;
  reasoningShare: number;
  reasoningTokens: number;
};

/**
 * Stable grouping key for a model id — the port of
 * `TokenExtractionUtility.normalizeModelKey`. Strips Cursor's `custom:` and
 * `vibeproxy:` prefixes, then trims and lowercases, so the same model logged
 * under different conventions collapses into one Model Mix row.
 */
export function normalizeModelKey(model: string): string {
  let normalized = model.trim();
  if (normalized.toLowerCase().startsWith('custom:')) {
    normalized = normalized.slice('custom:'.length);
  }
  if (normalized.toLowerCase().startsWith('vibeproxy:')) {
    normalized = normalized.slice('vibeproxy:'.length).replace(/^[ \-_:\t\n\r]+|[ \-_:\t\n\r]+$/g, '');
  }
  return normalized.trim().toLowerCase();
}

/** totalTokens = input + output + cacheCreation + cacheRead + reasoning (v27 backfill recipe). */
function eventTotalTokens(event: UsageCalendarEvent): number {
  return (
    event.inputTokens +
    event.outputTokens +
    event.cacheCreationTokens +
    event.cacheReadTokens +
    event.reasoningTokens
  );
}

/** Mirror of CalendarSelectionSnapshot.build over the loaded event window. */
export function selectionSnapshotFor(
  events: UsageCalendarEvent[],
  selectedDays: Set<number>,
  locale?: string
): SelectionSnapshot {
  const sortedDays = [...selectedDays].sort((a, b) => a - b);
  const selected = events.filter((e) => selectedDays.has(startOfDayLocal(attributionInstant(e))));

  let totalCost = 0;
  let totalTokens = 0;
  let cacheReadTokens = 0;
  let promptBasis = 0;
  let reasoningTokens = 0;
  const sessions = new Set<string>();
  const activeDaySet = new Set<number>();
  const providerTotals = new Map<string, number>();
  const modelTotals = new Map<string, number>();
  const projectTotals = new Map<string, number>();
  const matrix: number[][] = Array.from({ length: 7 }, () => Array<number>(24).fill(0));

  for (const event of selected) {
    const at = attributionInstant(event);
    const tokens = eventTotalTokens(event);
    totalCost += event.costUsd;
    totalTokens += tokens;
    cacheReadTokens += event.cacheReadTokens;
    promptBasis += event.inputTokens + event.cacheCreationTokens + event.cacheReadTokens;
    reasoningTokens += event.reasoningTokens;
    // Rows without a session id collapse into one synthetic bucket rather than
    // vanishing, matching the oracle's Set(selected.map(\.sessionId)).
    sessions.add(event.sessionId ?? '');
    activeDaySet.add(startOfDayLocal(at));
    providerTotals.set(event.providerId, (providerTotals.get(event.providerId) ?? 0) + event.costUsd);
    // Normalized key so `custom:`/`vibeproxy:` variants collapse into one row,
    // matching UsageStore.makeModelSummaries on macOS.
    const modelKey = normalizeModelKey(event.modelId);
    modelTotals.set(modelKey, (modelTotals.get(modelKey) ?? 0) + event.costUsd);
    const project = event.projectName && event.projectName.length > 0 ? event.projectName : 'Unattributed';
    projectTotals.set(project, (projectTotals.get(project) ?? 0) + event.costUsd);
    matrix[at.getDay()]![at.getHours()]! += event.costUsd;
  }

  // Per-day burn across the selection span — gap-filled so silent days draw
  // as zero bars instead of collapsing (ChartBucketing.dateBuckets).
  const dailyBurn: DailyBurnBucket[] = [];
  if (sortedDays.length > 0) {
    const costByDay = new Map<number, number>();
    for (const event of selected) {
      const day = startOfDayLocal(attributionInstant(event));
      costByDay.set(day, (costByDay.get(day) ?? 0) + event.costUsd);
    }
    const labelFmt = new Intl.DateTimeFormat(locale, { month: 'short', day: 'numeric' });
    const last = sortedDays[sortedDays.length - 1]!;
    let cursor = sortedDays[0]!;
    let guard = 0;
    while (cursor <= last && guard < 372) {
      dailyBurn.push({
        day: cursor,
        label: labelFmt.format(new Date(cursor)),
        costUsd: costByDay.get(cursor) ?? 0
      });
      cursor = addDaysLocal(cursor, 1);
      guard++;
    }
  }

  const providerShares = [...providerTotals.entries()]
    .map(([id, costUsd]) => ({ id, costUsd }))
    .sort((a, b) => (a.costUsd === b.costUsd ? (a.id < b.id ? -1 : 1) : b.costUsd - a.costUsd));
  const topModels = [...modelTotals.entries()]
    .map(([model, costUsd]) => ({ model, costUsd }))
    .sort((a, b) => (a.costUsd === b.costUsd ? (a.model < b.model ? -1 : 1) : b.costUsd - a.costUsd))
    .slice(0, 6);
  const projectShares = [...projectTotals.entries()]
    .map(([name, costUsd]) => ({ name, costUsd }))
    .sort((a, b) => (a.costUsd === b.costUsd ? (a.name < b.name ? -1 : 1) : b.costUsd - a.costUsd))
    .slice(0, 5);

  let peakWeekdayIndex: number | null = null;
  let peakHour: number | null = null;
  let peakValue = 0;
  for (let weekday = 0; weekday < 7; weekday++) {
    for (let hour = 0; hour < 24; hour++) {
      const value = matrix[weekday]![hour]!;
      if (value > peakValue) {
        peakValue = value;
        peakWeekdayIndex = weekday;
        peakHour = hour;
      }
    }
  }

  const blendedRate = totalTokens > 0 ? totalCost / totalTokens : 0;

  return {
    selectedDays: sortedDays,
    isEmpty: selected.length === 0,
    totalCost,
    totalTokens,
    sessionCount: sessions.size,
    activeDays: activeDaySet.size,
    averageCostPerDay: totalCost / Math.max(sortedDays.length, 1),
    dailyBurn,
    providerShares,
    topModels,
    projectShares,
    hourWeekdayCost: matrix,
    peakWeekdayIndex,
    peakHour,
    cacheHitRate: promptBasis > 0 ? cacheReadTokens / promptBasis : 0,
    cacheReadTokens,
    cacheSavingsEstimate: 0.9 * cacheReadTokens * blendedRate,
    reasoningShare: totalTokens > 0 ? reasoningTokens / totalTokens : 0,
    reasoningTokens
  };
}

// ─────────────────────────── Card layout ───────────────────────────

/**
 * Registry of every analytics card — mirrors CalendarCardKind raw values,
 * titles, footers, and default spans. The analytics grid is 3 columns wide;
 * span 3 = full width (surfaced as S/M/L sizes).
 */
export const CALENDAR_CARD_KINDS = [
  'kpis',
  'burnOverSelection',
  'providerMix',
  'modelMix',
  'hourOfDayHeatmap',
  'projectFocus',
  'cacheROI',
  'reasoningShare'
] as const;

export type CalendarCardKind = (typeof CALENDAR_CARD_KINDS)[number];

export type CalendarCardMeta = {
  kind: CalendarCardKind;
  title: string;
  whyItMatters: string;
  defaultSpan: number;
  /** Design-token accent (macOS CalendarCardKind.accent mapping). */
  accentVar: string;
};

export const CALENDAR_CARD_META: Record<CalendarCardKind, CalendarCardMeta> = {
  kpis: {
    kind: 'kpis',
    title: 'Key Numbers',
    whyItMatters: 'The selection at a glance — spend, volume, sessions, cadence.',
    defaultSpan: 3,
    accentVar: 'var(--color-brass-core)'
  },
  burnOverSelection: {
    kind: 'burnOverSelection',
    title: 'Burn Over Selection',
    whyItMatters: 'Day-by-day spend across the selected days.',
    defaultSpan: 3,
    accentVar: 'var(--color-brass-core)'
  },
  providerMix: {
    kind: 'providerMix',
    title: 'Provider Mix',
    whyItMatters: 'Where the money actually goes across providers.',
    defaultSpan: 1,
    accentVar: 'var(--color-macos-whimsy)'
  },
  modelMix: {
    kind: 'modelMix',
    title: 'Model Mix',
    whyItMatters: 'Which models earn their keep — and which quietly dominate.',
    defaultSpan: 1,
    accentVar: 'var(--color-macos-whimsy)'
  },
  hourOfDayHeatmap: {
    kind: 'hourOfDayHeatmap',
    title: 'When You Burn',
    whyItMatters: 'Your true working rhythm inside the selection.',
    defaultSpan: 3,
    accentVar: 'var(--color-macos-amber)'
  },
  projectFocus: {
    kind: 'projectFocus',
    title: 'Project Focus',
    whyItMatters: 'Which projects the selected days actually funded.',
    defaultSpan: 1,
    accentVar: 'var(--color-macos-whimsy)'
  },
  cacheROI: {
    kind: 'cacheROI',
    title: 'Cache Savings',
    whyItMatters: 'Prompt caching pays rent. This is the receipt.',
    defaultSpan: 1,
    accentVar: 'var(--color-macos-success)'
  },
  reasoningShare: {
    kind: 'reasoningShare',
    title: 'Reasoning Share',
    whyItMatters: 'Extended thinking is a hidden line item. Watch its share.',
    defaultSpan: 1,
    accentVar: 'var(--color-macos-blaze)'
  }
};

export type CalendarCardConfig = { kind: CalendarCardKind; isVisible: boolean; span: number };

export const CALENDAR_LAYOUT_STORAGE_KEY = 'openburnbar.linux.calendarLayout.v1';

function clampSpan(span: number): number {
  return Math.min(3, Math.max(1, Math.round(span)));
}

export function defaultCalendarCardConfig(kind: CalendarCardKind): CalendarCardConfig {
  return { kind, isVisible: true, span: CALENDAR_CARD_META[kind].defaultSpan };
}

export function defaultCalendarLayout(): CalendarCardConfig[] {
  return CALENDAR_CARD_KINDS.map(defaultCalendarCardConfig);
}

/** Dedupe + append missing kinds so every card always has exactly one slot. */
export function reconcileCalendarLayout(configs: CalendarCardConfig[]): CalendarCardConfig[] {
  const seen = new Set<CalendarCardKind>();
  const result: CalendarCardConfig[] = [];
  for (const config of configs) {
    if (seen.has(config.kind)) continue;
    seen.add(config.kind);
    result.push({ ...config, span: clampSpan(config.span) });
  }
  for (const kind of CALENDAR_CARD_KINDS) {
    if (!seen.has(kind)) result.push(defaultCalendarCardConfig(kind));
  }
  return result;
}

function isCalendarCardKind(value: unknown): value is CalendarCardKind {
  return typeof value === 'string' && (CALENDAR_CARD_KINDS as readonly string[]).includes(value);
}

/** JSON round-trip tolerant of unknown kinds (CalendarPageLayout.decode). */
export function decodeCalendarLayout(raw: string | null | undefined): CalendarCardConfig[] {
  if (!raw) return defaultCalendarLayout();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return defaultCalendarLayout();
    const known: CalendarCardConfig[] = [];
    for (const entry of parsed) {
      if (!entry || typeof entry !== 'object') continue;
      const kind = (entry as { kind?: unknown }).kind;
      if (!isCalendarCardKind(kind)) continue;
      const isVisible = (entry as { isVisible?: unknown }).isVisible;
      const span = (entry as { span?: unknown }).span;
      known.push({
        kind,
        isVisible: typeof isVisible === 'boolean' ? isVisible : true,
        span: typeof span === 'number' && Number.isFinite(span) ? clampSpan(span) : CALENDAR_CARD_META[kind].defaultSpan
      });
    }
    return reconcileCalendarLayout(known);
  } catch {
    return defaultCalendarLayout();
  }
}

export function encodeCalendarLayout(configs: CalendarCardConfig[]): string {
  return JSON.stringify(
    configs.map((config) => ({ kind: config.kind, isVisible: config.isVisible, span: config.span }))
  );
}

/** Move `kind` to the position currently held by `target` (drag-drop contract). */
export function moveCalendarCard(
  configs: CalendarCardConfig[],
  kind: CalendarCardKind,
  target: CalendarCardKind
): CalendarCardConfig[] {
  if (kind === target) return configs;
  const from = configs.findIndex((c) => c.kind === kind);
  const to = configs.findIndex((c) => c.kind === target);
  if (from < 0 || to < 0) return configs;
  const next = [...configs];
  const [config] = next.splice(from, 1);
  next.splice(to, 0, config!);
  return next;
}

export function setCalendarCardVisible(
  configs: CalendarCardConfig[],
  kind: CalendarCardKind,
  visible: boolean
): CalendarCardConfig[] {
  return configs.map((c) => (c.kind === kind ? { ...c, isVisible: visible } : c));
}

export function setCalendarCardSpan(
  configs: CalendarCardConfig[],
  kind: CalendarCardKind,
  span: number
): CalendarCardConfig[] {
  return configs.map((c) => (c.kind === kind ? { ...c, span: clampSpan(span) } : c));
}

// ─────────────────────────── Formatting ───────────────────────────

/** Compact USD cost (`formatAsCost` parity): sub-cent precision small, compact large. */
export function formatCostUsd(value: number): string {
  if (!Number.isFinite(value)) return '$0.00';
  if (Math.abs(value) >= 1000) {
    return `$${value.toLocaleString('en-US', { maximumFractionDigits: 0 })}`;
  }
  if (Math.abs(value) >= 100) return `$${value.toFixed(0)}`;
  return `$${value.toFixed(2)}`;
}

/** Token volume (`formatAsTokenVolume` parity): 1.2k / 3.4M. */
export function formatTokenCount(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '0';
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}k`;
  return String(Math.round(value));
}

/** Percent text: one decimal under 10%, whole percent otherwise. */
export function formatPercent(fraction: number): string {
  if (!Number.isFinite(fraction)) return '0%';
  const pct = fraction * 100;
  return `${pct < 10 ? pct.toFixed(1) : Math.round(pct)}%`;
}

const WEEKDAY_NAMES_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export function weekdayShortName(getDayIndex: number): string {
  return WEEKDAY_NAMES_SHORT[getDayIndex] ?? '';
}

/** 12-hour clock label (12am / 1pm) matching the macOS card headline. */
export function hourLabel(hour: number): string {
  if (hour === 0) return '12am';
  if (hour === 12) return '12pm';
  return hour < 12 ? `${hour}am` : `${hour - 12}pm`;
}
