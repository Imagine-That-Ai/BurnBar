import type { PointerEvent as ReactPointerEvent, MouseEvent as ReactMouseEvent } from 'react';
import { findProviderGlyph } from '../../providerGlyphs.js';
import {
  formatCostUsd,
  heatOpacity,
  monthGridFor,
  nextMonthStartLocal,
  startOfDayLocal,
  type MonthGrid,
  type MonthSnapshot
} from './calendarMath.js';
import { useCalendarStore } from '../../state/calendarStore.js';

/**
 * Month grid — port of CalendarMonthGrid + CalendarDayCell. Day cells are
 * buttons (keyboard-focusable); pointer drags paint a contiguous range from
 * the press-start day; ⇧/⌘|Ctrl clicks read modifiers off the click event.
 */

const fullDateFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'full' });

function DayCell({
  day,
  grid,
  snapshot,
  today
}: {
  day: number;
  grid: MonthGrid;
  snapshot: MonthSnapshot | null;
  today: number;
}) {
  const selection = useCalendarStore((s) => s.selection);
  const clickDay = useCalendarStore((s) => s.clickDay);
  const beginDrag = useCalendarStore((s) => s.beginDrag);
  const updateDrag = useCalendarStore((s) => s.updateDrag);

  const cost = snapshot?.dayCosts.get(day) ?? 0;
  const peak = snapshot?.peakDayCost ?? 0;
  const topProviders = snapshot?.dayProviders.get(day) ?? [];
  const isInMonth = day >= grid.monthStart && day < nextMonthStartLocal(grid.monthStart);
  const isToday = day === today;
  const isSelected = selection.selected.has(day);
  const fill = isSelected ? 0 : heatOpacity(cost, peak);

  const date = new Date(day);
  const labelParts = [fullDateFmt.format(date)];
  if (cost > 0) labelParts.push(formatCostUsd(cost));
  if (isToday) labelParts.push('Today');

  const onPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.button !== 0) return;
    // Modifier clicks are selection verbs, not drag starts.
    if (event.shiftKey || event.metaKey || event.ctrlKey) return;
    beginDrag(day);
  };
  const onPointerEnter = () => {
    if (selection.isDragging) updateDrag(day);
  };
  const onClick = (event: ReactMouseEvent<HTMLButtonElement>) => {
    clickDay(day, { shift: event.shiftKey, toggle: event.metaKey || event.ctrlKey });
  };

  return (
    <button
      type="button"
      className={[
        'calendar-day',
        isInMonth ? '' : 'calendar-day--outside',
        isToday ? 'calendar-day--today' : '',
        isSelected ? 'calendar-day--selected' : ''
      ]
        .filter(Boolean)
        .join(' ')}
      aria-label={labelParts.join(', ')}
      aria-pressed={isSelected}
      onPointerDown={onPointerDown}
      onPointerEnter={onPointerEnter}
      onClick={onClick}
    >
      <span
        className="calendar-day-heat"
        style={{ opacity: fill }}
        aria-hidden="true"
      />
      <span className="calendar-day-topline">
        <span className="calendar-day-number">{date.getDate()}</span>
        {cost > 0 ? <span className="calendar-day-cost">{formatCostUsd(cost)}</span> : null}
      </span>
      <span className="calendar-day-dots" aria-hidden="true">
        {topProviders.slice(0, 3).map((id) => (
          <span
            key={id}
            className="calendar-day-dot"
            style={{ background: findProviderGlyph(id).accent }}
          />
        ))}
      </span>
    </button>
  );
}

export function MonthGrid({ snapshot }: { snapshot: MonthSnapshot | null }) {
  const monthCursor = useCalendarStore((s) => s.monthCursor);
  const endDrag = useCalendarStore((s) => s.endDrag);
  const grid = monthGridFor(monthCursor, {});
  const today = startOfDayLocal(Date.now());

  return (
    <div
      className="calendar-grid"
      onPointerUp={endDrag}
      onPointerLeave={endDrag}
    >
      <div className="calendar-weekdays" aria-hidden="true">
        {grid.weekdaySymbols.map((symbol, i) => (
          <span key={`${symbol}-${i}`} className="calendar-weekday">
            {symbol}
          </span>
        ))}
      </div>
      <div className="calendar-weeks" role="group" aria-label="Days of the month">
        {grid.weeks.map((week, i) => (
          <div className="calendar-week" key={i}>
            {week.map((day) => (
              <DayCell key={day} day={day} grid={grid} snapshot={snapshot} today={today} />
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}
