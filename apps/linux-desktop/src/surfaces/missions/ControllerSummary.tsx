import type { CSSProperties } from 'react';

import type { RunwayStripStats } from './missionGroups.js';

const RUNWAY_CELLS: ReadonlyArray<{
  key: keyof RunwayStripStats;
  label: string;
  accentVar: string;
}> = [
  { key: 'inFlight', label: 'IN FLIGHT', accentVar: '--color-ember-core' },
  { key: 'planned', label: 'PLANNED', accentVar: '--color-warn' },
  { key: 'blocked', label: 'BLOCKED', accentVar: '--color-err' },
  { key: 'completed', label: 'COMPLETED', accentVar: '--color-ok' }
];

export function ControllerSummary({ stats }: { stats: RunwayStripStats }) {
  return (
    <div className="missions-runway-strip" role="status" aria-label="Mission runway metrics">
      {RUNWAY_CELLS.map((cell, index) => (
        <div key={cell.key} className="missions-runway-strip-cell-wrap">
          {index > 0 ? <div className="missions-runway-strip-divider" aria-hidden="true" /> : null}
          <div
            className="missions-runway-strip-cell"
            style={{ '--missions-runway-accent': `var(${cell.accentVar})` } as CSSProperties}
          >
            <p className="missions-runway-strip-label">{cell.label}</p>
            <p className="missions-runway-strip-value mono">{stats[cell.key]}</p>
          </div>
        </div>
      ))}
    </div>
  );
}