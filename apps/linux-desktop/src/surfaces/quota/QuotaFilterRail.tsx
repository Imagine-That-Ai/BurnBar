import type { QuotaSortMode, QuotaViewMode } from './quotaModel.js';

const SORT_OPTIONS: { id: QuotaSortMode; label: string }[] = [
  { id: 'urgency', label: 'Urgency' },
  { id: 'spend', label: 'Spend' },
  { id: 'alphabetical', label: 'A → Z' },
  { id: 'recentlyRefreshed', label: 'Recently refreshed' }
];

type Props = {
  viewMode: QuotaViewMode;
  sort: QuotaSortMode;
  showInactive: boolean;
  isRefreshing: boolean;
  onViewMode: (mode: QuotaViewMode) => void;
  onSort: (sort: QuotaSortMode) => void;
  onShowInactive: (show: boolean) => void;
  onRefreshAll: () => void;
};

export function QuotaFilterRail({
  viewMode,
  sort,
  showInactive,
  isRefreshing,
  onViewMode,
  onSort,
  onShowInactive,
  onRefreshAll
}: Props) {
  return (
    <div className="quota-filter-rail" role="toolbar" aria-label="Quota filters">
      <div className="quota-segmented" role="group" aria-label="View mode">
        <button
          type="button"
          className="quota-segment"
          data-active={viewMode === 'cards' ? 'true' : 'false'}
          aria-pressed={viewMode === 'cards'}
          onClick={() => onViewMode('cards')}
        >
          Cards
        </button>
        <button
          type="button"
          className="quota-segment"
          data-active={viewMode === 'list' ? 'true' : 'false'}
          aria-pressed={viewMode === 'list'}
          onClick={() => onViewMode('list')}
        >
          List
        </button>
      </div>

      <label className="quota-sort-label">
        Sort
        <select
          className="quota-sort-select"
          value={sort}
          onChange={(e) => onSort(e.target.value as QuotaSortMode)}
          aria-label="Sort subscriptions"
        >
          {SORT_OPTIONS.map((opt) => (
            <option key={opt.id} value={opt.id}>
              {opt.label}
            </option>
          ))}
        </select>
      </label>

      <button
        type="button"
        className="quota-inactive-pill"
        data-active={showInactive ? 'true' : 'false'}
        aria-pressed={showInactive}
        onClick={() => onShowInactive(!showInactive)}
      >
        Inactive plans
      </button>

      <button type="button" className="ghost quota-refresh-all" disabled={isRefreshing} onClick={onRefreshAll}>
        {isRefreshing ? 'Refreshing…' : 'Refresh all'}
      </button>
    </div>
  );
}