import type { CSSProperties } from 'react';
import {
  countMissionsForFilter,
  missionFilterAccent,
  MISSION_STATE_FILTERS,
  type MissionRecord,
  type MissionStateFilterKey
} from './missionGroups.js';
import type { PendingApproval } from '../../tauriBridge.js';
import { MissionProjectFilter } from './MissionProjectFilter.js';

export function MissionStateChipRail({
  missions,
  pendingApprovals,
  activeFilter,
  onFilterChange,
  projectFilter,
  projectOptions,
  onProjectFilterChange
}: {
  missions: MissionRecord[];
  pendingApprovals: PendingApproval[];
  activeFilter: MissionStateFilterKey;
  onFilterChange: (filter: MissionStateFilterKey) => void;
  projectFilter: string | null;
  projectOptions: { id: string; label: string }[];
  onProjectFilterChange: (projectId: string | null) => void;
}) {
  return (
    <div className="missions-filter-rail" role="group" aria-label="Mission state filter">
      <div className="missions-filter-rail-head">
        <p className="missions-filter-kicker">Filter</p>
        <MissionProjectFilter value={projectFilter} options={projectOptions} onChange={onProjectFilterChange} />
      </div>
      <div className="missions-filter-scroll">
        {MISSION_STATE_FILTERS.map(({ key, label }) => {
          const count = countMissionsForFilter(missions, key, pendingApprovals);
          const isActive = activeFilter === key;
          const accent = missionFilterAccent(key);
          return (
            <button
              key={key}
              type="button"
              className={`missions-filter-chip${isActive ? ' missions-filter-chip--active' : ''}`}
              aria-pressed={isActive}
              style={
                {
                  '--missions-filter-accent': accent
                } as CSSProperties
              }
              onClick={() => onFilterChange(key)}
            >
              <span className="missions-filter-chip-label">{label}</span>
              <span className="missions-filter-chip-count" aria-hidden="true">
                {count}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}