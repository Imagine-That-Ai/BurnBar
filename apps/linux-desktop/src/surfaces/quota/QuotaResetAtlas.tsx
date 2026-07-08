import type { CSSProperties } from 'react';
import { findProviderGlyph } from '../../providerGlyphs.js';
import type { SubscriptionEntry } from './quotaModel.js';

const DAYS_FORWARD = 7;

type DayBucket = {
  id: string;
  date: Date;
  entries: SubscriptionEntry[];
};

function startOfDay(d: Date): Date {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

function dayBuckets(entries: SubscriptionEntry[], now = new Date()): DayBucket[] {
  const base = startOfDay(now);
  const buckets: DayBucket[] = [];
  for (let i = 0; i < DAYS_FORWARD; i++) {
    const date = new Date(base);
    date.setDate(base.getDate() + i);
    buckets.push({ id: `day-${i}`, date, entries: [] });
  }
  for (const entry of entries) {
    if (!entry.nextResetDate) continue;
    const reset = startOfDay(new Date(entry.nextResetDate));
    const idx = Math.floor((reset.getTime() - base.getTime()) / 86_400_000);
    if (idx >= 0 && idx < DAYS_FORWARD) buckets[idx].entries.push(entry);
  }
  return buckets;
}

function dayLabel(date: Date, now: Date): string {
  const today = startOfDay(now);
  const diff = Math.round((startOfDay(date).getTime() - today.getTime()) / 86_400_000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Tomorrow';
  return date.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
}

function timeLabel(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

export function QuotaResetAtlas({ entries }: { entries: SubscriptionEntry[] }) {
  const now = new Date();
  const buckets = dayBuckets(entries, now);
  const total = buckets.reduce((n, b) => n + b.entries.length, 0);

  return (
    <section className="quota-reset-atlas" aria-labelledby="quota-reset-atlas-title">
      <header className="quota-reset-atlas-header">
        <h3 id="quota-reset-atlas-title" className="quota-reset-atlas-eyebrow mono">
          RESET ATLAS · NEXT 7 DAYS
        </h3>
        <p className="muted">
          {total === 0 ? 'No resets scheduled in this window' : `${total} reset event${total === 1 ? '' : 's'}`}
        </p>
      </header>
      <div className="quota-reset-atlas-hairline" aria-hidden="true" />
      <div className="quota-reset-grid" role="list">
        {buckets.map((bucket) => (
          <div key={bucket.id} className="quota-reset-day" role="listitem">
            <div className="quota-reset-day-label">{dayLabel(bucket.date, now)}</div>
            <div className="quota-reset-day-cells">
              {bucket.entries.length === 0 ? (
                <span className="quota-reset-empty muted" aria-hidden="true">
                  —
                </span>
              ) : (
                bucket.entries.map((entry) => {
                  const glyph = findProviderGlyph(entry.providerId);
                  const accent = glyph.accent.startsWith('#') ? 'var(--color-brass-core)' : glyph.accent;
                  return (
                    <div
                      key={`${bucket.id}-${entry.id}`}
                      className="quota-reset-cell"
                      style={{ '--reset-accent': accent } as CSSProperties}
                      title={`${entry.providerLabel} · ${entry.accountLabel}`}
                    >
                      <span className="quota-reset-provider">{entry.providerLabel}</span>
                      <span className="quota-reset-time mono">
                        {entry.nextResetDate ? timeLabel(entry.nextResetDate) : '—'}
                      </span>
                    </div>
                  );
                })
              )}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}