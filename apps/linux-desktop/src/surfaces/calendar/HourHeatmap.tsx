import {
  formatCostUsd,
  hourHeatOpacity,
  hourLabel,
  weekdayShortName
} from './calendarMath.js';

/**
 * 7×24 hour-of-day cost heatmap (ChartKitHeatmap parity): rows are weekdays
 * in Gregorian order (row 0 = Sunday), cells use the wider sqrt-scaled
 * opacity ramp of ChartKitHeatmap, peak cell called out in the aria summary.
 */
const HOUR_TICKS = [0, 6, 12, 18];

export function HourHeatmap({ matrix, accent }: { matrix: number[][]; accent: string }) {
  let peak = 0;
  let peakWeekday: number | null = null;
  let peakHour: number | null = null;
  for (let weekday = 0; weekday < 7; weekday++) {
    for (let hour = 0; hour < 24; hour++) {
      const value = matrix[weekday]?.[hour] ?? 0;
      if (value > peak) {
        peak = value;
        peakWeekday = weekday;
        peakHour = hour;
      }
    }
  }

  const ariaLabel =
    peakWeekday === null || peakHour === null
      ? 'No hour-of-day usage in the selection.'
      : `Hour-of-day cost heatmap. Peak ${weekdayShortName(peakWeekday)} ${hourLabel(peakHour)} at ${formatCostUsd(peak)}.`;

  return (
    <figure className="calendar-heat">
      <div className="calendar-heat-grid" role="img" aria-label={ariaLabel}>
        <div className="calendar-heat-hours" aria-hidden="true">
          <span className="calendar-heat-rowlabel" />
          {Array.from({ length: 24 }, (_, hour) => (
            <span key={hour} className="calendar-heat-hourtick">
              {HOUR_TICKS.includes(hour) ? hourLabel(hour) : ''}
            </span>
          ))}
        </div>
        {matrix.map((row, weekday) => (
          <div className="calendar-heat-row" key={weekday}>
            <span className="calendar-heat-rowlabel" aria-hidden="true">
              {weekdayShortName(weekday)}
            </span>
            {row.map((value, hour) => (
              <span
                key={hour}
                className="calendar-heat-cell"
                style={
                  value > 0
                    ? { background: accent, opacity: hourHeatOpacity(value, peak) }
                    : undefined
                }
              />
            ))}
          </div>
        ))}
      </div>
      <table className="visually-hidden">
        <caption>Cost by weekday and hour</caption>
        <thead>
          <tr>
            <th scope="col">Weekday</th>
            {Array.from({ length: 24 }, (_, hour) => (
              <th scope="col" key={hour}>
                {hourLabel(hour)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {matrix.map((row, weekday) => (
            <tr key={weekday}>
              <th scope="row">{weekdayShortName(weekday)}</th>
              {row.map((value, hour) => (
                <td key={hour}>{value.toFixed(4)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </figure>
  );
}
