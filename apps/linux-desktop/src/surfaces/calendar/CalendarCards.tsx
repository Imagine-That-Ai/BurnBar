import { ConceptStatTile } from '../../components/ConceptStatTile.js';
import { ProviderLogoView } from '../../components/ProviderLogoView.js';
import { findProviderGlyph } from '../../providerGlyphs.js';
import { useCalendarStore } from '../../state/calendarStore.js';
import { MixBar } from '../insights/MixBar.js';
import { BurnBars } from './BurnBars.js';
import { HourHeatmap } from './HourHeatmap.js';
import {
  CALENDAR_CARD_META,
  formatCostUsd,
  formatPercent,
  formatTokenCount,
  hourLabel,
  weekdayShortName,
  type CalendarCardConfig,
  type CalendarCardKind,
  type SelectionSnapshot
} from './calendarMath.js';

/**
 * Selection-driven analytics card gallery — port of CalendarAnalyticsPanel /
 * CalendarCardView. Cards render prepared snapshot data only; all aggregation
 * lives in calendarMath. Layout verbs (hide / resize S·M·L / reorder) ride
 * keyboard-accessible controls in each card's options menu.
 */

function modelDisplayName(modelId: string): string {
  // Same convention as tauriBridge buildMix: capitalize the raw model key.
  return modelId.charAt(0).toUpperCase() + modelId.slice(1);
}

function headline(kind: CalendarCardKind, snapshot: SelectionSnapshot): string {
  switch (kind) {
    case 'kpis':
      return formatCostUsd(snapshot.totalCost);
    case 'burnOverSelection':
      return `${formatCostUsd(snapshot.totalCost)} · ${snapshot.selectedDays.length}d`;
    case 'providerMix': {
      const top = snapshot.providerShares[0];
      if (!top || snapshot.totalCost <= 0) return '—';
      return `${findProviderGlyph(top.id).label} ${Math.round((top.costUsd / snapshot.totalCost) * 100)}%`;
    }
    case 'modelMix':
      return snapshot.topModels[0] ? modelDisplayName(snapshot.topModels[0].model) : '—';
    case 'hourOfDayHeatmap':
      if (snapshot.peakWeekdayIndex === null || snapshot.peakHour === null) return '—';
      return `Peak ${weekdayShortName(snapshot.peakWeekdayIndex)} ${hourLabel(snapshot.peakHour)}`;
    case 'projectFocus':
      return snapshot.projectShares[0]?.name ?? '—';
    case 'cacheROI':
      return `≈${formatCostUsd(snapshot.cacheSavingsEstimate)} saved`;
    case 'reasoningShare':
      return formatPercent(snapshot.reasoningShare);
  }
}

function isKindEmpty(kind: CalendarCardKind, snapshot: SelectionSnapshot): boolean {
  switch (kind) {
    case 'kpis':
      return snapshot.isEmpty;
    case 'burnOverSelection':
      return !snapshot.dailyBurn.some((b) => b.costUsd > 0);
    case 'providerMix':
      return snapshot.providerShares.length === 0;
    case 'modelMix':
      return snapshot.topModels.length === 0;
    case 'hourOfDayHeatmap':
      return snapshot.peakHour === null;
    case 'projectFocus':
      return snapshot.projectShares.length === 0;
    case 'cacheROI':
      return snapshot.cacheReadTokens === 0;
    case 'reasoningShare':
      return snapshot.reasoningTokens === 0;
  }
}

function KpiTiles({ snapshot }: { snapshot: SelectionSnapshot }) {
  return (
    <div className="calendar-kpis">
      <ConceptStatTile label="Total Cost" value={formatCostUsd(snapshot.totalCost)} />
      <ConceptStatTile label="Total Tokens" value={formatTokenCount(snapshot.totalTokens)} />
      <ConceptStatTile label="Sessions" value={String(snapshot.sessionCount)} />
      <ConceptStatTile label="Active Days" value={String(snapshot.activeDays)} />
      <ConceptStatTile label="Avg Cost/Day" value={formatCostUsd(snapshot.averageCostPerDay)} />
    </div>
  );
}

function ProviderMixRows({ snapshot }: { snapshot: SelectionSnapshot }) {
  const rows = snapshot.providerShares.slice(0, 6);
  const peak = Math.max(...rows.map((r) => r.costUsd), 0.0001);
  return (
    <div className="calendar-ranked">
      {rows.map((row) => {
        const glyph = findProviderGlyph(row.id);
        return (
          <div className="calendar-ranked-row" key={row.id}>
            <span className="calendar-ranked-head">
              <ProviderLogoView id={row.id} size={14} accent={glyph.accent} />
              <span className="calendar-ranked-label">{glyph.label}</span>
              <span className="calendar-ranked-value">{formatCostUsd(row.costUsd)}</span>
            </span>
            <span className="calendar-ranked-track" aria-hidden="true">
              <span
                className="calendar-ranked-fill"
                style={{
                  width: `${Math.max(3, (row.costUsd / peak) * 100).toFixed(1)}%`,
                  background: glyph.accent
                }}
              />
            </span>
          </div>
        );
      })}
    </div>
  );
}

function ProjectFocusRows({ snapshot }: { snapshot: SelectionSnapshot }) {
  const rows = snapshot.projectShares;
  const peak = Math.max(...rows.map((r) => r.costUsd), 0.0001);
  return (
    <div className="calendar-ranked">
      {rows.map((row) => (
        <div className="calendar-ranked-row" key={row.name}>
          <span className="calendar-ranked-head">
            <span className="calendar-ranked-label">{row.name}</span>
            <span className="calendar-ranked-value">{formatCostUsd(row.costUsd)}</span>
          </span>
          <span className="calendar-ranked-track" aria-hidden="true">
            <span
              className="calendar-ranked-fill calendar-ranked-fill--neutral"
              style={{ width: `${Math.max(3, (row.costUsd / peak) * 100).toFixed(1)}%` }}
            />
          </span>
        </div>
      ))}
    </div>
  );
}

function BigStatTile({
  value,
  label,
  detail,
  accent
}: {
  value: string;
  label: string;
  detail: string;
  accent: string;
}) {
  return (
    <div className="calendar-bigstat">
      <span className="calendar-bigstat-value" style={{ color: accent }}>
        {value}
      </span>
      <span className="calendar-bigstat-label">{label}</span>
      <span className="calendar-bigstat-detail">{detail}</span>
    </div>
  );
}

function CardContent({ kind, snapshot }: { kind: CalendarCardKind; snapshot: SelectionSnapshot }) {
  const meta = CALENDAR_CARD_META[kind];
  if (isKindEmpty(kind, snapshot)) {
    return <div className="calendar-card-empty">Nothing on these days yet</div>;
  }
  switch (kind) {
    case 'kpis':
      return <KpiTiles snapshot={snapshot} />;
    case 'burnOverSelection':
      return <BurnBars buckets={snapshot.dailyBurn} accent={meta.accentVar} />;
    case 'providerMix':
      return <ProviderMixRows snapshot={snapshot} />;
    case 'modelMix': {
      const total = snapshot.topModels.reduce((s, m) => s + m.costUsd, 0);
      const entries = snapshot.topModels.map((m) => ({
        id: m.model,
        label: modelDisplayName(m.model),
        pct: total > 0 ? Math.round((m.costUsd / total) * 100) : 0
      }));
      return (
        <MixBar
          title="Model mix"
          entries={entries}
          ariaLabel={`Model mix: ${entries.map((e) => `${e.label} ${e.pct}%`).join(', ')}`}
        />
      );
    }
    case 'hourOfDayHeatmap':
      return <HourHeatmap matrix={snapshot.hourWeekdayCost} accent={meta.accentVar} />;
    case 'projectFocus':
      return <ProjectFocusRows snapshot={snapshot} />;
    case 'cacheROI':
      return (
        <BigStatTile
          value={`≈${formatCostUsd(snapshot.cacheSavingsEstimate)}`}
          label="estimated savings"
          detail={`${formatPercent(snapshot.cacheHitRate)} hit rate · ${formatTokenCount(snapshot.cacheReadTokens)} cache-read tokens`}
          accent={meta.accentVar}
        />
      );
    case 'reasoningShare':
      return (
        <BigStatTile
          value={formatPercent(snapshot.reasoningShare)}
          label="of tokens were reasoning"
          detail={`${formatTokenCount(snapshot.reasoningTokens)} reasoning tokens`}
          accent={meta.accentVar}
        />
      );
  }
}

function CardOptions({
  config,
  visible
}: {
  config: CalendarCardConfig;
  visible: CalendarCardConfig[];
}) {
  const hideCard = useCalendarStore((s) => s.hideCard);
  const moveCard = useCalendarStore((s) => s.moveCard);
  const setCardSpan = useCalendarStore((s) => s.setCardSpan);
  const meta = CALENDAR_CARD_META[config.kind];
  const index = visible.findIndex((c) => c.kind === config.kind);
  const earlier = index > 0 ? visible[index - 1] : undefined;
  const later = index >= 0 && index < visible.length - 1 ? visible[index + 1] : undefined;

  return (
    <details className="calendar-card-menu">
      <summary aria-label={`${meta.title} card options`}>⋯</summary>
      <div className="calendar-card-menu-body" role="group" aria-label={`${meta.title} layout controls`}>
        <span className="calendar-card-menu-label">Size</span>
        <div className="calendar-card-menu-row">
          {([1, 2, 3] as const).map((span) => (
            <button
              key={span}
              type="button"
              className="ghost calendar-card-menu-btn"
              aria-pressed={config.span === span}
              onClick={() => setCardSpan(config.kind, span)}
            >
              {span === 1 ? 'S' : span === 2 ? 'M' : 'L'}
            </button>
          ))}
        </div>
        <div className="calendar-card-menu-row">
          <button
            type="button"
            className="ghost calendar-card-menu-btn"
            disabled={!earlier}
            onClick={() => earlier && moveCard(config.kind, earlier.kind)}
          >
            Move earlier
          </button>
          <button
            type="button"
            className="ghost calendar-card-menu-btn"
            disabled={!later}
            onClick={() => later && moveCard(config.kind, later.kind)}
          >
            Move later
          </button>
        </div>
        <div className="calendar-card-menu-row">
          <button
            type="button"
            className="ghost calendar-card-menu-btn"
            onClick={() => hideCard(config.kind)}
          >
            Hide card
          </button>
        </div>
      </div>
    </details>
  );
}

function AnalyticsCard({
  config,
  snapshot,
  visible
}: {
  config: CalendarCardConfig;
  snapshot: SelectionSnapshot;
  visible: CalendarCardConfig[];
}) {
  const meta = CALENDAR_CARD_META[config.kind];
  return (
    <section
      className="calendar-card"
      style={{ gridColumn: `span ${config.span}` }}
      aria-label={`${meta.title}. ${headline(config.kind, snapshot)}. ${meta.whyItMatters}`}
    >
      <header className="calendar-card-header">
        <span className="calendar-card-glyph" style={{ color: meta.accentVar }} aria-hidden="true">
          ▪
        </span>
        <h3 className="calendar-card-title">{meta.title}</h3>
        <span className="calendar-card-headline">{headline(config.kind, snapshot)}</span>
        <CardOptions config={config} visible={visible} />
      </header>
      <div className="calendar-card-body">
        <CardContent kind={config.kind} snapshot={snapshot} />
      </div>
      <p className="calendar-card-why">{meta.whyItMatters}</p>
    </section>
  );
}

export function CalendarCards({ snapshot }: { snapshot: SelectionSnapshot }) {
  const layout = useCalendarStore((s) => s.layout);
  const showCard = useCalendarStore((s) => s.showCard);
  const resetLayout = useCalendarStore((s) => s.resetLayout);
  const visible = layout.filter((c) => c.isVisible);
  const hidden = layout.filter((c) => !c.isVisible);

  return (
    <div className="calendar-cards-wrap">
      <div className="calendar-cards">
        {visible.map((config) => (
          <AnalyticsCard key={config.kind} config={config} snapshot={snapshot} visible={visible} />
        ))}
      </div>
      {hidden.length > 0 ? (
        <div className="calendar-hidden" role="group" aria-label="Hidden cards">
          <span className="muted">Hidden:</span>
          {hidden.map((config) => (
            <button
              key={config.kind}
              type="button"
              className="ghost calendar-hidden-chip"
              onClick={() => showCard(config.kind)}
            >
              Show {CALENDAR_CARD_META[config.kind].title}
            </button>
          ))}
          <button type="button" className="ghost calendar-hidden-chip" onClick={resetLayout}>
            Reset layout
          </button>
        </div>
      ) : null}
    </div>
  );
}
