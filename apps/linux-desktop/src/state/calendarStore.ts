import { create } from 'zustand';
import { fixtureUsageCalendarEvents } from '../daemonFixture.js';
import type { UsageCalendarEvent } from '../tauriBridge.js';
import {
  CALENDAR_LAYOUT_STORAGE_KEY,
  addMonthsLocal,
  decodeCalendarLayout,
  defaultCalendarLayout,
  emptyCalendarSelection,
  encodeCalendarLayout,
  moveCalendarCard,
  selectionBeginDrag,
  selectionEndDrag,
  selectionExtend,
  selectionSelect,
  selectionToggle,
  selectionUpdateDrag,
  setCalendarCardSpan,
  setCalendarCardVisible,
  startOfDayLocal,
  type CalendarCardConfig,
  type CalendarCardKind,
  type CalendarSelection
} from '../surfaces/calendar/calendarMath.js';
import { useShellStore } from './shellStore.js';

/**
 * Calendar lane store — owns the usage event window, the visible month, the
 * day selection, and the persisted analytics-card layout. All aggregation
 * lives in surfaces/calendar/calendarMath.ts; this store is state + the
 * live/fixture/offline ladder only.
 */

function readPersistedLayout(
  storage: Pick<Storage, 'getItem'> | null = typeof localStorage !== 'undefined' ? localStorage : null
): CalendarCardConfig[] {
  try {
    return decodeCalendarLayout(storage?.getItem(CALENDAR_LAYOUT_STORAGE_KEY));
  } catch {
    return defaultCalendarLayout();
  }
}

function writePersistedLayout(
  layout: CalendarCardConfig[],
  storage: Pick<Storage, 'setItem'> | null = typeof localStorage !== 'undefined' ? localStorage : null
): void {
  try {
    storage?.setItem(CALENDAR_LAYOUT_STORAGE_KEY, encodeCalendarLayout(layout));
  } catch {
    // Layout persistence is a convenience; the in-memory layout still applies.
  }
}

export type CalendarState = {
  events: UsageCalendarEvent[] | null;
  loading: boolean;
  error: string | null;
  /** Day key inside the visible month (grid derives from it). */
  monthCursor: number;
  selection: CalendarSelection;
  layout: CalendarCardConfig[];
  load(): Promise<void>;
  goToNextMonth(): void;
  goToPreviousMonth(): void;
  goToToday(): void;
  /** Plain click / ⇧-click extend / ⌘|Ctrl-click toggle, per macOS semantics. */
  clickDay(day: number, modifiers?: { shift?: boolean; toggle?: boolean }): void;
  beginDrag(day: number): void;
  updateDrag(day: number): void;
  endDrag(): void;
  clearSelection(): void;
  hideCard(kind: CalendarCardKind): void;
  showCard(kind: CalendarCardKind): void;
  moveCard(kind: CalendarCardKind, target: CalendarCardKind): void;
  setCardSpan(kind: CalendarCardKind, span: number): void;
  resetLayout(): void;
};

export const useCalendarStore = create<CalendarState>()((set, get) => {
  const persistLayout = (layout: CalendarCardConfig[]) => {
    writePersistedLayout(layout);
    set({ layout });
  };
  return {
    events: null,
    loading: false,
    error: null,
    monthCursor: startOfDayLocal(Date.now()),
    // macOS CalendarView selects today on appear when the selection is empty.
    selection: selectionSelect(emptyCalendarSelection(), Date.now()),
    layout: readPersistedLayout(),

    async load() {
      const { fixtureMode, bridge } = useShellStore.getState();
      if (fixtureMode) {
        set({ events: fixtureUsageCalendarEvents(), loading: false, error: null });
        return;
      }
      if (!bridge) {
        set({ events: null, loading: false, error: 'Packaged shell required for live data.' });
        return;
      }
      set({ loading: true, error: null });
      try {
        const events = await bridge.usageCalendar();
        set({ events, loading: false, error: null });
      } catch (e) {
        set({
          events: null,
          loading: false,
          error: e instanceof Error ? e.message : 'Request failed'
        });
      }
    },

    goToNextMonth() {
      set((state) => ({ monthCursor: addMonthsLocal(state.monthCursor, 1) }));
    },
    goToPreviousMonth() {
      set((state) => ({ monthCursor: addMonthsLocal(state.monthCursor, -1) }));
    },
    goToToday() {
      set({ monthCursor: startOfDayLocal(Date.now()) });
    },

    clickDay(day, modifiers = {}) {
      const { selection } = get();
      if (modifiers.toggle) {
        set({ selection: selectionToggle(selection, day) });
      } else if (modifiers.shift) {
        set({ selection: selectionExtend(selection, day) });
      } else {
        set({ selection: selectionSelect(selection, day) });
      }
    },
    beginDrag(day) {
      set((state) => ({ selection: selectionBeginDrag(state.selection, day) }));
    },
    updateDrag(day) {
      set((state) => ({ selection: selectionUpdateDrag(state.selection, day) }));
    },
    endDrag() {
      set((state) => ({ selection: selectionEndDrag(state.selection) }));
    },
    clearSelection() {
      set({ selection: emptyCalendarSelection() });
    },

    hideCard(kind) {
      persistLayout(setCalendarCardVisible(get().layout, kind, false));
    },
    showCard(kind) {
      persistLayout(setCalendarCardVisible(get().layout, kind, true));
    },
    moveCard(kind, target) {
      persistLayout(moveCalendarCard(get().layout, kind, target));
    },
    setCardSpan(kind, span) {
      persistLayout(setCalendarCardSpan(get().layout, kind, span));
    },
    resetLayout() {
      persistLayout(defaultCalendarLayout());
    }
  };
});
