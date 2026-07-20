import { useEffect, useMemo, useState } from 'react';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { QuotaCard, QuotaListRow } from '../../components/QuotaCard.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useProvidersStore } from '../../state/providersStore.js';
import type { ProviderCatalog } from '../../tauriBridge.js';
import { QuotaFilterRail } from './QuotaFilterRail.js';
import { QuotaResetAtlas } from './QuotaResetAtlas.js';
import { SubscriptionConstellationHero } from './SubscriptionConstellationHero.js';
import {
  aggregateSummary,
  buildInactiveSlots,
  buildSubscriptionEntries,
  filterByProvider,
  loadQuotaPrefs,
  providerOrbEntries,
  saveQuotaPrefs,
  sortEntries,
  type QuotaSortMode,
  type QuotaViewMode
} from './quotaModel.js';
import './quota.css';

export function QuotaWorkspaceSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const setRoute = useShellStore((s) => s.setRoute);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const catalog = useProvidersStore((s) => s.catalog);
  const loading = useProvidersStore((s) => s.loading);
  const error = useProvidersStore((s) => s.error);
  const load = useProvidersStore((s) => s.load);

  const [prefs, setPrefs] = useState(loadQuotaPrefs);
  const [focusProviderId, setFocusProviderId] = useState<string | null>(null);
  const [lastCatalog, setLastCatalog] = useState<ProviderCatalog | null>(null);

  useEffect(() => {
    // A transient daemon refresh failure should not erase a usable quota
    // snapshot. Explicitly empty catalogs still clear the retained view.
    if (catalog === null) return;
    setLastCatalog(catalog.length > 0 ? catalog : null);
  }, [catalog]);

  useLaneLoad(load);

  const workspaceCatalog = catalog === null ? lastCatalog : catalog.length > 0 ? catalog : null;
  const allEntries = useMemo(
    () => (workspaceCatalog ? buildSubscriptionEntries(workspaceCatalog) : []),
    [workspaceCatalog]
  );
  const inactiveSlots = useMemo(
    () => (workspaceCatalog ? buildInactiveSlots(workspaceCatalog) : []),
    [workspaceCatalog]
  );

  const activeEntries = useMemo(() => {
    let rows = allEntries;
    if (!prefs.showInactive) {
      rows = rows.filter((e) => !e.isInactive);
    }
    return sortEntries(rows, prefs.sort);
  }, [allEntries, prefs.showInactive, prefs.sort]);

  const displayedEntries = useMemo(
    () => filterByProvider(activeEntries, focusProviderId),
    [activeEntries, focusProviderId]
  );

  const summary = useMemo(() => aggregateSummary(displayedEntries), [displayedEntries]);
  const orbEntries = useMemo(() => providerOrbEntries(activeEntries), [activeEntries]);
  const totalProviderCount = useMemo(() => new Set(allEntries.map((e) => e.providerId)).size, [allEntries]);

  const showOffline = !fixtureMode && !bridge && !loading && error != null;
  const showingStaleCatalog = catalog === null && lastCatalog !== null;
  const provenance = fixtureMode
    ? 'fixture transcript'
    : showingStaleCatalog
      ? 'last available daemon provider catalog'
      : 'live daemon provider catalog';

  function updatePrefs(patch: Partial<typeof prefs>) {
    setPrefs((prev) => {
      const next = { ...prev, ...patch };
      saveQuotaPrefs(next);
      return next;
    });
  }

  function handleOrbTap(providerId: string) {
    setFocusProviderId((prev) => (prev === providerId ? null : providerId));
  }

  return (
    <div className="quota-workspace">
      {showOffline ? (
        <OfflineNotice
          status={status}
          summary={
            showingStaleCatalog
              ? 'Live quota catalog is unavailable; showing the last available snapshot until the packaged shell reconnects.'
              : 'Subscription vault needs the packaged shell or fixture mode before quota cards can load.'
          }
          fixtureMode={fixtureMode}
        />
      ) : null}
      {showingStaleCatalog && !showOffline ? (
        <Banner tone="degraded" role="status">
          <p>Live quota catalog is unavailable. Showing the last available quota snapshot.</p>
          {error ? <p className="muted">{error}</p> : null}
          <button type="button" className="ghost" onClick={() => void load()}>
            Retry quota catalog
          </button>
        </Banner>
      ) : null}
      {error && !showOffline && !showingStaleCatalog ? (
        <Banner tone="degraded" role="alert">
          <p>{error}</p>
          <button type="button" className="ghost" onClick={() => void load()}>
            Retry
          </button>
        </Banner>
      ) : null}

      {loading && !workspaceCatalog ? (
        <div className="quota-skeleton" aria-busy="true" aria-label="Loading subscription vault">
          <div className="quota-skeleton-hero" />
          <div className="quota-skeleton-grid" />
        </div>
      ) : null}

      {catalog !== null && catalog.length === 0 ? (
        <p className="quota-empty" role="status">
          No providers linked — connect from the daemon settings.
        </p>
      ) : null}

      {workspaceCatalog && workspaceCatalog.length > 0 ? (
        <>
          <p className="quota-provenance muted">Data source: {provenance}</p>
          <SubscriptionConstellationHero
            entries={displayedEntries}
            summary={summary}
            orbEntries={orbEntries}
            selectedProviderId={focusProviderId}
            totalProviderCount={totalProviderCount}
            onOrbTap={handleOrbTap}
            onClearSelection={() => setFocusProviderId(null)}
          />

          {focusProviderId ? (
            <div className="quota-focus-banner" role="status">
              <span>
                Focused on{' '}
                <strong>{displayedEntries[0]?.providerLabel ?? focusProviderId}</strong> — cards, atlas, and summaries
                show this provider only.
              </span>
              <button type="button" className="ghost" onClick={() => setFocusProviderId(null)}>
                Show all providers
              </button>
            </div>
          ) : null}

          <QuotaFilterRail
            viewMode={prefs.viewMode}
            sort={prefs.sort}
            showInactive={prefs.showInactive}
            isRefreshing={loading}
            onViewMode={(viewMode: QuotaViewMode) => updatePrefs({ viewMode })}
            onSort={(sort: QuotaSortMode) => updatePrefs({ sort })}
            onShowInactive={(showInactive) => updatePrefs({ showInactive })}
            onRefreshAll={() => void load()}
          />

          {prefs.showInactive && inactiveSlots.length > 0 ? (
            <section className="quota-inactive-strip" aria-label="Inactive provider slots">
              <p className="quota-inactive-eyebrow mono">NO ACTIVE PLANS · SHOWING UNCONFIGURED PROVIDERS</p>
              <ul>
                {inactiveSlots.map((slot) => (
                  <li key={slot.id}>
                    <span>{slot.providerLabel}</span>
                    <span className="muted">Ready to connect</span>
                  </li>
                ))}
              </ul>
            </section>
          ) : null}

          {displayedEntries.length === 0 ? (
            <p className="quota-empty-focus muted" role="status">
              No active plans for this provider in fixture data — toggle inactive plans or clear focus.
            </p>
          ) : prefs.viewMode === 'list' ? (
            <div className="quota-list" role="list">
              {displayedEntries.map((entry) => (
                <QuotaListRow key={entry.id} entry={entry} onManage={() => setRoute('settings')} />
              ))}
            </div>
          ) : (
            <div className="quota-card-grid">
              {displayedEntries.map((entry) => (
                <QuotaCard key={entry.id} entry={entry} onManage={() => setRoute('settings')} />
              ))}
            </div>
          )}

          <QuotaResetAtlas entries={displayedEntries} />
        </>
      ) : null}
    </div>
  );
}
