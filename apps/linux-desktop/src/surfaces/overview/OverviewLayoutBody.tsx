import { useMemo } from 'react';
import { ProviderListPanel } from '../../components/ProviderListPanel.js';
import { HomeLivingLayout } from '../../dashboard/HomeLivingLayout.js';
import { createHomeSlot, createRowAppetite } from '../../dashboard/homeSpaceBudget.js';
import type { DashboardLayout } from '../../dashboard/dashboardLayout.js';
import type { MixEntry, MissionListResult, SessionEntry, UsageSummary } from '../../tauriBridge.js';
import { AtelierHero } from './AtelierHero.js';
import { AtlasSplit } from './AtlasSplit.js';
import { RecentActivityList } from './RecentActivityList.js';
import { StreamRiver } from './StreamRiver.js';
import { UsageTiles } from './UsageTiles.js';
import type { OverviewProviderRow, SpendCurveModel } from './overviewAtelierData.js';
import {
  ATLAS_ROW_UNIT,
  PROVIDER_ROW_UNIT,
  STREAM_ROW_UNIT,
  buildAtlasModel,
  resolveStreamEntries
} from './overviewHomeModel.js';

type OverviewLayoutBodyProps = {
  layout: DashboardLayout;
  summary: UsageSummary | null;
  cacheHitRatePct: number | null;
  lastRefreshedAt: Date | null;
  curveModel: SpendCurveModel;
  providerRows: OverviewProviderRow[];
  providerMix: MixEntry[];
  sessions: SessionEntry[];
  missions: MissionListResult | null;
  fixtureMode: boolean;
  live: boolean;
  loading: boolean;
};

export function OverviewLayoutBody(props: OverviewLayoutBodyProps) {
  const entries = resolveStreamEntries(props.summary, props.sessions);
  const atlas = buildAtlasModel({
    missions: props.missions,
    events: entries,
    providerMix: props.providerMix
  });

  switch (props.layout) {
    case 'stream':
      return <StreamRiver entries={entries} />;
    case 'atlas':
      return (
        <AtlasSplit split={atlas.split} attention={atlas.attention} rest={atlas.rest} kinds={atlas.kinds} />
      );
    case 'classic':
      return <LedgerBody {...props} eventCount={entries.length} />;
    case 'aurora':
      return <FocusBody {...props} />;
    default:
      return <CanvasBody {...props} />;
  }
}

function CanvasBody({
  layout,
  summary,
  cacheHitRatePct,
  curveModel,
  providerRows,
  fixtureMode,
  loading
}: OverviewLayoutBodyProps) {
  const ambientRail = layout === 'atelier';
  const slots = useMemo(
    () => [
      createHomeSlot({
        id: 'overview.rail',
        rank: 1,
        floor: 72 + PROVIDER_ROW_UNIT,
        ideal: 72 + PROVIDER_ROW_UNIT * Math.min(8, Math.max(providerRows.length, 1)),
        stretch: 0,
        isAmbient: ambientRail,
        rows: createRowAppetite({
          available: providerRows.length,
          baseline: Math.min(6, providerRows.length),
          unit: PROVIDER_ROW_UNIT,
          ceiling: 16
        })
      }),
      createHomeSlot({
        id: 'overview.main',
        rank: 0,
        floor: 280,
        ideal: 420,
        stretch: 1
      })
    ],
    [ambientRail, providerRows.length]
  );

  return (
    <HomeLivingLayout slots={slots} gutter={20} padding={4}>
      {(id, placement) => {
        if (id === 'overview.rail') {
          return (
            <ProviderListPanel
              rows={providerRows}
              title="Providers"
              logoSize={40}
              skeleton={loading && providerRows.length === 0}
              rowCount={placement.rowCount}
            />
          );
        }
        return (
          <AtelierHero
            summary={summary}
            cacheHitRatePct={cacheHitRatePct}
            curveModel={curveModel}
            fixtureMode={fixtureMode}
            loading={loading}
            providerCount={providerRows.length}
            kernelForward={layout === 'atelier' || layout === 'constellation'}
          />
        );
      }}
    </HomeLivingLayout>
  );
}

function LedgerBody({
  summary,
  cacheHitRatePct,
  lastRefreshedAt,
  fixtureMode,
  live,
  loading,
  eventCount
}: OverviewLayoutBodyProps & { eventCount: number }) {
  const slots = useMemo(
    () => [
      createHomeSlot({ id: 'ledger.tiles', rank: 0, floor: 140, ideal: 160 }),
      createHomeSlot({
        id: 'ledger.list',
        rank: 1,
        floor: 80 + STREAM_ROW_UNIT * 3,
        ideal: 80 + STREAM_ROW_UNIT * 8,
        stretch: 1,
        rows: createRowAppetite({
          available: eventCount,
          baseline: Math.min(6, eventCount),
          unit: STREAM_ROW_UNIT,
          ceiling: 24
        })
      })
    ],
    [eventCount]
  );

  return (
    <HomeLivingLayout slots={slots} gutter={16} padding={4}>
      {(id, placement) =>
        id === 'ledger.tiles' ? (
          <UsageTiles
            summary={summary}
            cacheHitRatePct={cacheHitRatePct}
            lastRefreshedAt={lastRefreshedAt}
            skeleton={loading && !summary}
          />
        ) : (
          <RecentActivityList
            summary={summary}
            fixtureMode={fixtureMode}
            live={live}
            limit={placement.rowCount}
          />
        )
      }
    </HomeLivingLayout>
  );
}

function FocusBody({ summary, loading }: OverviewLayoutBodyProps) {
  const queued = Math.max(0, (summary?.recentEvents.length ?? 0) - 1);
  const slots = useMemo(() => {
    const next = [
      createHomeSlot({
        id: 'focus.lead',
        rank: 0,
        floor: 190,
        ideal: 320,
        stretch: 1
      })
    ];
    if (queued > 0) {
      next.push(
        createHomeSlot({
          id: 'focus.queue',
          rank: 1,
          floor: 45 + ATLAS_ROW_UNIT,
          ideal: 45 + ATLAS_ROW_UNIT * 3,
          rows: createRowAppetite({
            available: queued,
            baseline: 1,
            unit: ATLAS_ROW_UNIT,
            ceiling: 6
          })
        })
      );
    }
    return next;
  }, [queued]);

  const lead = summary?.recentEvents[0];
  const rest = summary?.recentEvents.slice(1) ?? [];

  return (
    <HomeLivingLayout slots={slots} gutter={16} padding={8}>
      {(id, placement) => {
        if (id === 'focus.lead') {
          return (
            <section className="home-section home-section--featured">
              <p className="home-section__eyebrow">Today</p>
              <p className="focus-lead__value tabular-nums living-tick">
                {loading && !summary
                  ? '—'
                  : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(
                      summary?.todayCostUsd ?? 0
                    )}
              </p>
              <p className="focus-lead__copy" style={{ maxWidth: 680 }}>
                {lead ? lead.title : 'Nothing needs you. Detectors are still running.'}
              </p>
            </section>
          );
        }
        return (
          <section className="home-section">
            <p className="home-section__eyebrow">Next</p>
            <ol className="atlas-ladder">
              {rest.slice(0, placement.rowCount).map((event) => (
                <li key={event.id} className="atlas-ladder__row">
                  <span className="atlas-ladder__title">{event.title}</span>
                  <span className="atlas-ladder__comparison muted">{event.detail}</span>
                </li>
              ))}
            </ol>
          </section>
        );
      }}
    </HomeLivingLayout>
  );
}
