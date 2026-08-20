import { useMemo } from 'react';
import { HomeLivingLayout } from '../../dashboard/HomeLivingLayout.js';
import { createHomeSlot, createRowAppetite } from '../../dashboard/homeSpaceBudget.js';
import { HomeSection } from './HomeSection.js';
import {
  STREAM_DAY_CHROME,
  STREAM_ROW_UNIT,
  formatStreamTime,
  groupStreamByDay,
  type StreamEntry
} from './overviewHomeModel.js';

const SLOT = 'stream.river';

export function StreamRiver({ entries }: { entries: StreamEntry[] }) {
  const daysAvailable = Math.max(1, new Set(entries.map((entry) => entry.at.slice(0, 10))).size);
  const slots = useMemo(
    () => [
      createHomeSlot({
        id: SLOT,
        rank: 0,
        floor: STREAM_DAY_CHROME + STREAM_ROW_UNIT * 3,
        ideal: STREAM_DAY_CHROME * daysAvailable + STREAM_ROW_UNIT * Math.max(entries.length, 3),
        stretch: 1,
        rows: createRowAppetite({
          available: entries.length,
          baseline: Math.min(3, entries.length),
          unit: STREAM_ROW_UNIT,
          ceiling: 40
        })
      })
    ],
    [daysAvailable, entries.length]
  );

  return (
    <HomeLivingLayout slots={slots} gutter={16} padding={8}>
      {(_, placement) => <River entries={entries} limit={placement.rowCount} />}
    </HomeLivingLayout>
  );
}

function River({ entries, limit }: { entries: StreamEntry[]; limit: number }) {
  if (entries.length === 0) {
    return (
      <HomeSection eyebrow="Stream" accent="var(--color-tier-server-readable)">
        <p className="home-section__empty">Nothing has happened yet today.</p>
      </HomeSection>
    );
  }

  const days = groupStreamByDay(entries, Math.max(1, limit));
  const shown = days.reduce((sum, day) => sum + day.entries.length, 0);
  const hidden = Math.max(0, entries.length - shown);

  return (
    <div className="stream-river">
      {days.map((day) => (
        <HomeSection
          key={day.key}
          eyebrow={day.label}
          accent={day.isSpike ? 'var(--color-seal-crimson)' : 'var(--color-brass-core)'}
          emphasis={day.isSpike ? 'featured' : 'standard'}
          accessory={
            day.isSpike ? (
              <span className="stream-river__spike">Spike</span>
            ) : (
              <span className="stream-river__count tabular-nums">{day.entries.length}</span>
            )
          }
        >
          <ol className="stream-river__list">
            {day.entries.map((entry, index) => (
              <li
                key={entry.id}
                className="stream-river__row living-slot__arrive"
                style={{
                  ['--living-stagger' as string]: `calc(${Math.min(index, 4)} * var(--motion-stagger-step-ms) * 1ms)`
                }}
              >
                <time className="stream-river__time mono" dateTime={entry.at}>
                  {formatStreamTime(entry.at)}
                </time>
                <span className="stream-river__spine" aria-hidden />
                <div className="stream-river__copy">
                  <p className="stream-river__title">{entry.title}</p>
                  <p className="stream-river__detail muted">{entry.detail}</p>
                </div>
              </li>
            ))}
          </ol>
        </HomeSection>
      ))}
      {hidden > 0 ? <p className="stream-river__more muted">{hidden} more in the full activity lane</p> : null}
    </div>
  );
}
