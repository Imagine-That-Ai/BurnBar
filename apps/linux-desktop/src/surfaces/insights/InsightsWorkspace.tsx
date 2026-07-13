import { useMemo, useState, type FormEvent } from 'react';
import type { UsageInsights } from '../../tauriBridge.js';
import { MixBar } from './MixBar.js';
import { StatCallout } from './StatCallout.js';
import { TrendChart } from './TrendChart.js';
import { weekOverWeekTokenDeltaPct } from './insightsChartMath.js';

type InsightWidget = {
  id: string;
  title: string;
  summary: string;
  source: string;
  kind: 'trend' | 'stat' | 'provider' | 'model';
};

type InsightsWorkspaceProps = {
  data: UsageInsights;
  sourceLabel: string;
  onRefresh: () => void;
  onFollowUp: (question: string) => void;
};

function widgetsFor(data: UsageInsights, sourceLabel: string): InsightWidget[] {
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
      source: sourceLabel,
      kind: 'trend'
    },
    {
      id: 'cache-rate',
      title: 'Cache efficiency',
      summary: `${Math.round(data.cacheHitRatePct)}% cache hit rate${delta === null ? '' : `; ${Math.round(delta)}% week over week`}.`,
      source: sourceLabel,
      kind: 'stat'
    },
    {
      id: 'provider-mix',
      title: 'Provider mix',
      summary: provider ? `${provider.label} leads recorded share at ${provider.pct}%.` : 'No provider mix is available.',
      source: sourceLabel,
      kind: 'provider'
    },
    {
      id: 'model-mix',
      title: 'Model mix',
      summary: model ? `${model.label} leads recorded share at ${model.pct}%.` : 'No model mix is available.',
      source: sourceLabel,
      kind: 'model'
    }
  ];
}

export function InsightsWorkspace({ data, sourceLabel, onRefresh, onFollowUp }: InsightsWorkspaceProps) {
  const widgets = useMemo(() => widgetsFor(data, sourceLabel), [data, sourceLabel]);
  const [selectedID, setSelectedID] = useState(widgets[0]?.id ?? 'usage-trend');
  const [composerValue, setComposerValue] = useState('');
  const [showAudit, setShowAudit] = useState(false);
  const selected = widgets.find((widget) => widget.id === selectedID) ?? widgets[0];

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
              onClick={() => setSelectedID(widget.id)}
            >
              <span>{widget.title}</span>
              <small>{widget.kind}</small>
            </button>
          ))}
        </nav>
      </aside>

      <main className="insights-workspace-main">
        <header className="insights-workspace-toolbar">
          <div>
            <span className="insights-eyebrow">Insights</span>
            <h2>Usage observatory</h2>
            <p className="data-source muted">Provenance: {sourceLabel}</p>
          </div>
          <div className="insights-workspace-actions">
            <button type="button" className="secondary" onClick={() => setShowAudit(true)} aria-haspopup="dialog">
              Audit
            </button>
            <button type="button" className="secondary" onClick={onRefresh} aria-label="Refresh insights">
              Refresh
            </button>
          </div>
        </header>

        <section className="insights-canvas-grid" aria-label="Insight widgets">
          <article className="insights-widget insights-widget--wide">
            <div className="insights-widget-heading">
              <div>
                <h3>Usage trend</h3>
                <p>Recorded weekly tokens and cost</p>
              </div>
              <button type="button" className="insights-link-button" onClick={() => setSelectedID('usage-trend')}>
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
              <button type="button" className="insights-link-button" onClick={() => setSelectedID('cache-rate')}>
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
              <button type="button" className="insights-link-button" onClick={() => setSelectedID('provider-mix')}>
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
              <button type="button" className="insights-link-button" onClick={() => setSelectedID('model-mix')}>
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
      </main>

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
                <dd>{selected.source === 'fixture transcript' ? 'Local fixture' : 'Live daemon usage'}</dd>
              </div>
              <div>
                <dt>Scope</dt>
                <dd>Weekly, provider, model, and cache aggregates</dd>
              </div>
              <div>
                <dt>Interpretation</dt>
                <dd>Describes recorded activity only; it does not infer quality or savings.</dd>
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
            <p>Every widget in this canvas is derived from the same bounded usage response.</p>
            <ul className="insights-audit-list">
              <li><strong>Source:</strong> {sourceLabel}</li>
              <li><strong>Widgets:</strong> {widgets.length} normalized views</li>
              <li><strong>Latest period:</strong> {data.weekly.at(-1)?.label ?? 'Unavailable'}</li>
              <li><strong>Cloud/shared evidence:</strong> Not included in this Linux surface</li>
            </ul>
          </section>
        </div>
      ) : null}
    </div>
  );
}
