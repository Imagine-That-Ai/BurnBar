import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import type { UsageInsights } from '../../tauriBridge.js';
import { MixBar } from './MixBar.js';
import { StatCallout } from './StatCallout.js';
import { TrendChart } from './TrendChart.js';
import { weekOverWeekTokenDeltaPct } from './insightsChartMath.js';
import { resolveInsightsEvidence, resolveQualitativeCapability } from './insightsEvidence.js';
import {
  readInsightsWorkspace,
  writeInsightsWorkspace,
  type InsightsCanvasLayout,
  type InsightsWorkspaceSnapshot
} from './insightsWorkspacePersistence.js';

type InsightWidget = {
  id: string;
  title: string;
  summary: string;
  source: string;
  sourceID: string;
  sourceState: 'verified' | 'unavailable';
  sourceDetail: string;
  kind: 'trend' | 'stat' | 'provider' | 'model';
};

type InsightsWorkspaceProps = {
  data: UsageInsights;
  sourceLabel: string;
  onRefresh: () => void;
  onFollowUp: (question: string) => void;
  accountScope?: string;
};

function widgetsFor(data: UsageInsights, sourceLabel: string): InsightWidget[] {
  const evidence = resolveInsightsEvidence(data, sourceLabel);
  const latest = data.weekly.at(-1);
  const delta = weekOverWeekTokenDeltaPct(data.weekly);
  const provider = [...data.providerMix].sort((a, b) => b.pct - a.pct)[0];
  const model = [...data.modelMix].sort((a, b) => b.pct - a.pct)[0];
  return [
    {
      id: 'usage-trend',
      title: 'Usage trend',
      summary: latest
        ? `${latest.tokens.toLocaleString()} tokens in the latest recorded period.`
        : 'No recorded period is available.',
      source: evidence.label,
      sourceID: evidence.sourceID,
      sourceState: evidence.state,
      sourceDetail: evidence.detail,
      kind: 'trend'
    },
    {
      id: 'cache-rate',
      title: 'Cache efficiency',
      summary: `${Math.round(data.cacheHitRatePct)}% cache hit rate${delta === null ? '' : `; ${Math.round(delta)}% week over week`}.`,
      source: evidence.label,
      sourceID: evidence.sourceID,
      sourceState: evidence.state,
      sourceDetail: evidence.detail,
      kind: 'stat'
    },
    {
      id: 'provider-mix',
      title: 'Provider mix',
      summary: provider ? `${provider.label} leads recorded share at ${provider.pct}%.` : 'No provider mix is available.',
      source: evidence.label,
      sourceID: evidence.sourceID,
      sourceState: evidence.state,
      sourceDetail: evidence.detail,
      kind: 'provider'
    },
    {
      id: 'model-mix',
      title: 'Model mix',
      summary: model ? `${model.label} leads recorded share at ${model.pct}%.` : 'No model mix is available.',
      source: evidence.label,
      sourceID: evidence.sourceID,
      sourceState: evidence.state,
      sourceDetail: evidence.detail,
      kind: 'model'
    }
  ];
}

export function InsightsWorkspace({
  data,
  sourceLabel,
  onRefresh,
  onFollowUp,
  accountScope = 'local'
}: InsightsWorkspaceProps) {
  const evidence = useMemo(() => resolveInsightsEvidence(data, sourceLabel), [data, sourceLabel]);
  const widgets = useMemo(() => widgetsFor(data, evidence.label), [data, evidence]);
  const widgetIDs = useMemo(() => widgets.map((widget) => widget.id), [widgets]);
  const widgetFingerprint = widgetIDs.join('|');
  const [workspace, setWorkspace] = useState<InsightsWorkspaceSnapshot>(() =>
    readInsightsWorkspace(accountScope, widgetIDs)
  );
  const initializedScopeRef = useRef<string | null>(null);
  const [composerValue, setComposerValue] = useState('');
  const [showAudit, setShowAudit] = useState(false);
  const selectedID = workspace.selectedWidgetID;
  const layout = workspace.layout;
  const selected = widgets.find((widget) => widget.id === selectedID) ?? widgets[0];
  const qualitative = resolveQualitativeCapability(data);

  useEffect(() => {
    setWorkspace(readInsightsWorkspace(accountScope, widgetIDs));
  }, [accountScope, widgetFingerprint, widgetIDs]);

  useEffect(() => {
    // The hydration effect above must win when the account context changes;
    // skip the first write for each scope so old-account state cannot leak.
    if (initializedScopeRef.current !== accountScope) {
      initializedScopeRef.current = accountScope;
      return;
    }
    writeInsightsWorkspace(accountScope, workspace);
  }, [accountScope, workspace]);

  function selectWidget(widgetID: string): void {
    if (!widgetIDs.includes(widgetID)) return;
    setWorkspace((current) => ({ ...current, selectedWidgetID: widgetID }));
  }

  function setLayout(nextLayout: InsightsCanvasLayout): void {
    setWorkspace((current) => ({ ...current, layout: nextLayout }));
  }

  function submitFollowUp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const question = composerValue.trim();
    if (!question) return;
    onFollowUp(question);
    setComposerValue('');
  }

  return (
    <div className="insights-workspace" data-testid="insights-workspace">
      <aside className="insights-canvas-library" aria-label="Insight canvases">
        <div className="insights-workspace-heading">
          <span className="insights-eyebrow">Canvases</span>
          <strong>Usage observatory</strong>
        </div>
        <p className="insights-library-copy">Select a panel to inspect its recorded evidence and follow up in chat.</p>
        <nav aria-label="Insight canvas list">
          {widgets.map((widget) => (
            <button
              type="button"
              key={widget.id}
              className={widget.id === selected?.id ? 'insights-canvas-item is-selected' : 'insights-canvas-item'}
              aria-pressed={widget.id === selected?.id}
              onClick={() => selectWidget(widget.id)}
            >
              <span>{widget.title}</span>
              <small>{widget.kind}</small>
            </button>
          ))}
        </nav>
      </aside>

      <section className="insights-workspace-main" aria-labelledby="insights-workspace-title">
        <header className="insights-workspace-toolbar">
          <div>
            <span className="insights-eyebrow">Insights</span>
            <h2 id="insights-workspace-title">Usage observatory</h2>
            <p className="data-source muted">Provenance: {evidence.label}</p>
          </div>
          <div className="insights-workspace-actions">
            <div className="insights-density-picker" role="group" aria-label="Canvas density">
              <button
                type="button"
                className="secondary"
                aria-pressed={layout === 'balanced'}
                onClick={() => setLayout('balanced')}
              >
                Balanced
              </button>
              <button
                type="button"
                className="secondary"
                aria-pressed={layout === 'compact'}
                onClick={() => setLayout('compact')}
              >
                Compact
              </button>
            </div>
            <button type="button" className="secondary" onClick={() => setShowAudit(true)} aria-haspopup="dialog">
              Audit
            </button>
            <button type="button" className="secondary" onClick={onRefresh} aria-label="Refresh insights">
              Refresh
            </button>
          </div>
        </header>

        <section
          className={`insights-canvas-grid${layout === 'compact' ? ' insights-canvas-grid--compact' : ''}`}
          aria-label="Insight widgets"
          data-layout={layout}
        >
          <article className="insights-widget insights-widget--wide">
            <div className="insights-widget-heading">
              <div>
                <h3>Usage trend</h3>
                <p>Recorded weekly tokens and cost</p>
              </div>
              <button type="button" className="insights-link-button" onClick={() => selectWidget('usage-trend')}>
                Inspect
              </button>
            </div>
            <TrendChart weekly={data.weekly} />
          </article>
          <article className="insights-widget">
            <div className="insights-widget-heading">
              <div>
                <h3>Cache efficiency</h3>
                <p>Normalized usage aggregate</p>
              </div>
              <button type="button" className="insights-link-button" onClick={() => selectWidget('cache-rate')}>
                Inspect
              </button>
            </div>
            <StatCallout cacheHitRatePct={data.cacheHitRatePct} caption="Cache hit rate" />
          </article>
          <article className="insights-widget">
            <div className="insights-widget-heading">
              <div>
                <h3>Provider mix</h3>
                <p>Share of recorded activity</p>
              </div>
              <button type="button" className="insights-link-button" onClick={() => selectWidget('provider-mix')}>
                Inspect
              </button>
            </div>
            <MixBar
              title="Provider mix"
              entries={data.providerMix}
              ariaLabel={`Provider mix: ${data.providerMix.map((entry) => `${entry.label} ${entry.pct}%`).join(', ')}`}
            />
          </article>
          <article className="insights-widget">
            <div className="insights-widget-heading">
              <div>
                <h3>Model mix</h3>
                <p>Share of recorded activity</p>
              </div>
              <button type="button" className="insights-link-button" onClick={() => selectWidget('model-mix')}>
                Inspect
              </button>
            </div>
            <MixBar
              title="Model mix"
              entries={data.modelMix}
              ariaLabel={`Model mix: ${data.modelMix.map((entry) => `${entry.label} ${entry.pct}%`).join(', ')}`}
            />
          </article>
        </section>

        <form className="insights-composer" onSubmit={submitFollowUp}>
          <label htmlFor="insights-follow-up">Ask about this data</label>
          <div className="insights-composer-row">
            <input
              id="insights-follow-up"
              value={composerValue}
              onChange={(event) => setComposerValue(event.target.value)}
              placeholder="e.g. Compare this week with the prior period"
              maxLength={500}
            />
            <button type="submit" className="primary" disabled={!composerValue.trim()}>
              Open in chat
            </button>
          </div>
        </form>
      </section>

      <aside className="insights-inspector" aria-label="Insight inspector">
        <div className="insights-workspace-heading">
          <span className="insights-eyebrow">Inspector</span>
          <strong>{selected?.title ?? 'No widget selected'}</strong>
        </div>
        {selected ? (
          <>
            <p>{selected.summary}</p>
            <dl className="insights-inspector-list">
              <div>
                <dt>Source</dt>
                <dd>
                  <span>{selected.source === 'fixture transcript' ? 'Local fixture' : selected.source}</span>{' '}
                  <code data-testid="insights-source-id">{selected.sourceID}</code>
                </dd>
              </div>
              <div>
                <dt>Evidence state</dt>
                <dd data-testid="insights-evidence-state">
                  {selected.sourceState === 'verified' ? 'Verified source' : 'Unavailable source'}
                  <span className="insights-inspector-detail">{selected.sourceDetail}</span>
                </dd>
              </div>
              <div>
                <dt>Scope</dt>
                <dd>Weekly, provider, model, and cache aggregates</dd>
              </div>
              <div>
                <dt>Interpretation</dt>
                <dd>Describes recorded activity only; it does not infer quality or savings.</dd>
              </div>
              <div>
                <dt>Qualitative analysis</dt>
                <dd data-testid="insights-qualitative-state">
                  {qualitative.state === 'unavailable' ? 'Unavailable' : qualitative.state}
                  <span className="insights-inspector-detail">{qualitative.reason}</span>
                </dd>
              </div>
            </dl>
            <button
              type="button"
              className="secondary insights-inspector-follow-up"
              onClick={() => onFollowUp(`Explain the ${selected.title.toLowerCase()} evidence from the current Insights canvas.`)}
            >
              Explain in chat
            </button>
          </>
        ) : (
          <p className="muted">Choose a widget to inspect its source and scope.</p>
        )}
      </aside>

      {showAudit ? (
        <div className="insights-audit-backdrop" role="presentation" onMouseDown={() => setShowAudit(false)}>
          <section
            className="insights-audit-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="insights-audit-title"
            aria-describedby="insights-audit-description"
            onMouseDown={(event) => event.stopPropagation()}
          >
            <div className="insights-widget-heading">
              <div>
                <span className="insights-eyebrow">Evidence trail</span>
                <h2 id="insights-audit-title">Insights audit</h2>
              </div>
              <button type="button" className="secondary" onClick={() => setShowAudit(false)}>
                Close
              </button>
            </div>
            <p id="insights-audit-description">Every widget in this canvas is derived from the same bounded usage response.</p>
            <ul className="insights-audit-list">
              <li><strong>Source:</strong> {evidence.label}</li>
              <li><strong>Source ID:</strong> {selected?.sourceID ?? 'unavailable'}</li>
              <li><strong>Widgets:</strong> {widgets.length} normalized views</li>
              <li><strong>Latest period:</strong> {data.weekly.at(-1)?.label ?? 'Unavailable'}</li>
              <li><strong>Cloud/shared evidence:</strong> Not included in this Linux surface</li>
              <li><strong>Qualitative analysis:</strong> {qualitative.state === 'unavailable' ? 'Unavailable' : qualitative.state}</li>
            </ul>
          </section>
        </div>
      ) : null}
    </div>
  );
}
