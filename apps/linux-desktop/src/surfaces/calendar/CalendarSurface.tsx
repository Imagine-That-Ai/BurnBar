import { useMemo } from 'react';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useCalendarStore } from '../../state/calendarStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { CalendarCards } from './CalendarCards.js';
import { MonthGrid } from './MonthGrid.js';
import {
  formatCostUsd,
  monthGridFor,
  monthLabel,
  monthSnapshotFor,
  selectionSnapshotFor
} from './calendarMath.js';
import './calendar.css';

/**
 * Calendar analytics surface — Linux port of the macOS Calendar page
 * (CalendarView). Month grid + selection-driven analytics cards on the
 * live → labelled-fixture → OfflineNotice ladder; day bucketing is local-tz
 * and all aggregation is pure calendarMath.
 */

function CalendarSkeleton() {
  return (
    <div className="calendar-surface calendar-surface--loading" aria-busy="true">
      <div className="calendar-layout">
        <div className="calendar-panel calendar-skeleton-grid" />
        <div className="calendar-skeleton-cards">
          <div className="calendar-panel calendar-skeleton-card" />
          <div className="calendar-panel calendar-skeleton-card" />
          <div className="calendar-panel calendar-skeleton-card" />
        </div>
      </div>
    </div>
  );
}

function MonthHeader() {
  const monthCursor = useCalendarStore((s) => s.monthCursor);
  const selection = useCalendarStore((s) => s.selection);
  const goToNextMonth = useCalendarStore((s) => s.goToNextMonth);
  const goToPreviousMonth = useCalendarStore((s) => s.goToPreviousMonth);
  const goToToday = useCalendarStore((s) => s.goToToday);
  const clearSelection = useCalendarStore((s) => s.clearSelection);

  const selectedCount = selection.selected.size;
  return (
    <div className="calendar-monthbar">
      <div className="calendar-monthbar-nav" role="group" aria-label="Month navigation">
        <button type="button" className="ghost calendar-nav-btn" aria-label="Previous month" onClick={goToPreviousMonth}>
          ‹
        </button>
        <h3 className="calendar-month-label">{monthLabel(monthCursor, undefined)}</h3>
        <button type="button" className="ghost calendar-nav-btn" aria-label="Next month" onClick={goToNextMonth}>
          ›
        </button>
        <button type="button" className="ghost calendar-today-btn" onClick={goToToday}>
          Today
        </button>
      </div>
      <p className="calendar-selection-summary muted" role="status">
        {selectedCount === 0
          ? 'No days selected — click, ⇧-click, Ctrl/⌘-click, or drag in the grid.'
          : `${selectedCount} day${selectedCount === 1 ? '' : 's'} selected`}
        {selectedCount > 0 ? (
          <>
            {' · '}
            <button type="button" className="ghost calendar-clear-btn" onClick={clearSelection}>
              Clear
            </button>
          </>
        ) : null}
      </p>
    </div>
  );
}

export function CalendarSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const events = useCalendarStore((s) => s.events);
  const loading = useCalendarStore((s) => s.loading);
  const error = useCalendarStore((s) => s.error);
  const load = useCalendarStore((s) => s.load);
  const monthCursor = useCalendarStore((s) => s.monthCursor);
  const selection = useCalendarStore((s) => s.selection);

  useLaneLoad(load);

  const grid = useMemo(() => monthGridFor(monthCursor, {}), [monthCursor]);
  const monthSnapshot = useMemo(
    () => (events ? monthSnapshotFor(events, grid) : null),
    [events, grid]
  );
  const selectionSnapshot = useMemo(
    () => selectionSnapshotFor(events ?? [], selection.selected),
    [events, selection.selected]
  );

  if (loading && !events) {
    return <CalendarSkeleton />;
  }

  if (error && !events) {
    return (
      <div className="calendar-surface">
        <Banner tone="degraded">
          <p>{error}</p>
          <button type="button" className="primary" onClick={() => void load()}>
            Retry
          </button>
        </Banner>
      </div>
    );
  }

  const offline = !fixtureMode && !bridge && !loading && !error;
  if (offline) {
    return (
      <OfflineNotice
        status={status}
        summary="Calendar needs the packaged shell and local daemon before usage history can load."
        fixtureMode={fixtureMode}
      />
    );
  }

  if (events && events.length === 0) {
    return (
      <div className="calendar-surface">
        <p className="data-source muted">
          Provenance: {fixtureMode ? 'fixture transcript' : 'live daemon usage events'}
        </p>
        <p className="calendar-empty muted">
          No usage events in the recent window yet — the calendar fills in after your first sessions.
        </p>
      </div>
    );
  }

  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon usage events';

  return (
    <div className="calendar-surface">
      <p className="data-source muted">Provenance: {sourceLabel}</p>
      <MonthHeader />
      <div className="calendar-layout">
        <section className="calendar-panel calendar-grid-panel" aria-label="Month grid">
          <MonthGrid snapshot={monthSnapshot} />
          <p className="calendar-month-total muted">
            {monthSnapshot && monthSnapshot.monthTotalCost > 0
              ? `${formatCostUsd(monthSnapshot.monthTotalCost)} in ${monthLabel(monthCursor, undefined)}`
              : `No spend recorded in ${monthLabel(monthCursor, undefined)}`}
          </p>
        </section>
        <CalendarCards snapshot={selectionSnapshot} />
      </div>
    </div>
  );
}
