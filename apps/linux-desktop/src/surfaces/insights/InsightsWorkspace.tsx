import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import type { MixEntry, UsageInsights, UsageInsightsQualitativeCitation } from '../../tauriBridge.js';
import { MixBar } from './MixBar.js';
import { StatCallout } from './StatCallout.js';
import { TrendChart } from './TrendChart.js';
import { weekOverWeekTokenDeltaPct } from './insightsChartMath.js';
import {
  insightsCitationPrompt,
  resolveInsightsEvidence,
  resolveQualitativeCapability,
  uniqueInsightsCitations
} from './insightsEvidence.js';
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

type InsightCompareScope = {
  id: string;
  label: string;
  detail: string;
  kind: 'provider' | 'model' | 'widget';
  source: string;
  sourceID: string;
  sourceState: 'verified' | 'unavailable';
  sourceDetail: string;
  entry?: MixEntry;
  widget?: InsightWidget;
};

type InsightsWorkspaceProps = {
  data: UsageInsights;
  sourceLabel: string;
  onRefresh: () => void;
  onFollowUp: (question: string) => void;
  accountScope?: string;
};

function InsightsCitationChips({
  citations,
  label,
  onOpen
}: {
  citations: readonly UsageInsightsQualitativeCitation[];
  label: string;
  onOpen: (citation: UsageInsightsQualitativeCitation) => void;
}) {
  const bounded = uniqueInsightsCitations(citations);
  if (bounded.length === 0) return null;
  return (
    <div className="insights-citation-group">
      <span className="insights-citation-label">{label}</span>
      <div className="insights-citation-chips" role="list" aria-label={label}>
        {bounded.map((citation) => (
          <button
            type="button"
            key={citation.id}
            className="insights-citation-chip"
            onClick={() => onOpen(citation)}
            aria-label={`Open citation: ${citation.label}`}
            title={`Citation ${citation.id}`}
          >
            <span aria-hidden="true">&gt;</span>
            {citation.label}
          </button>
        ))}
      </div>
    </div>
  );
}

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

function validMixEntry(entry: MixEntry): boolean {
  return (
    typeof entry.id === 'string' &&
    entry.id.trim().length > 0 &&
    typeof entry.label === 'string' &&
    entry.label.trim().length > 0 &&
    Number.isFinite(entry.pct) &&
    entry.pct >= 0 &&
    entry.pct <= 100
  );
}

function compareScopesFor(
  data: UsageInsights,
  widgets: readonly InsightWidget[],
  evidence: ReturnType<typeof resolveInsightsEvidence>
): InsightCompareScope[] {
  // A compare column is a claim about the same response as the canvas. Do not
  // let malformed or missing authority metadata turn a renderer projection
  // into something that looks like live evidence.
  if (evidence.state !== 'verified') return [];

  const scopes: InsightCompareScope[] = [];
  for (const entry of data.providerMix.filter(validMixEntry)) {
    scopes.push({
      id: `provider:${entry.id}`,
      label: entry.label,
      detail: `${entry.pct}% of recorded provider activity.`,
      kind: 'provider',
      source: evidence.label,
      sourceID: evidence.sourceID,
      sourceState: evidence.state,
      sourceDetail: evidence.detail,
      entry
    });
  }
  for (const entry of data.modelMix.filter(validMixEntry)) {
    scopes.push({
      id: `model:${entry.id}`,
      label: entry.label,
      detail: `${entry.pct}% of recorded model activity.`,
      kind: 'model',
      source: evidence.label,
      sourceID: evidence.sourceID,
      sourceState: evidence.state,
      sourceDetail: evidence.detail,
      entry
    });
  }
  for (const widget of widgets) {
    if (widget.sourceState !== 'verified') continue;
    scopes.push({
      id: `widget:${widget.id}`,
      label: widget.title,
      detail: widget.summary,
      kind: 'widget',
      source: widget.source,
      sourceID: widget.sourceID,
      sourceState: widget.sourceState,
      sourceDetail: widget.sourceDetail,
      widget
    });
  }
  return scopes;
}

function compareScopeKindLabel(scope: InsightCompareScope): string {
  if (scope.kind === 'widget') return 'Widget';
  return scope.kind === 'provider' ? 'Provider scope' : 'Model scope';
}

function compareScopeControlLabel(scope: InsightCompareScope): string {
  return `${compareScopeKindLabel(scope)}: ${scope.label}`;
}

function InsightCompareColumn({
  scope,
  data,
  onRemove
}: {
  scope: InsightCompareScope;
  data: UsageInsights;
  onRemove: () => void;
}) {
  const titleID = `insights-compare-title-${scope.id.replace(/[^a-zA-Z0-9_-]/g, '-')}`;
  const entry = scope.entry;
  const widget = scope.widget;

  return (
    <article className="insights-compare-column" aria-labelledby={titleID}>
      <header className="insights-compare-column-heading">
        <div>
          <span className="insights-eyebrow">{compareScopeKindLabel(scope)}</span>
          <h3 id={titleID}>{scope.label}</h3>
        </div>
        <button
          type="button"
          className="insights-compare-remove"
          onClick={onRemove}
          aria-label={`Remove ${scope.label} from compare`}
          title={`Remove ${scope.label} from compare`}
        >
          <span aria-hidden="true">×</span>
        </button>
      </header>
      <p className="insights-compare-summary">{scope.detail}</p>
      {entry ? (
        <div className="insights-compare-share" role="group" aria-label={`${scope.label} recorded share`}>
          <div className="insights-compare-share-value">
            <span>Recorded share</span>
            <strong>{entry.pct}%</strong>
          </div>
          <div
            className="insights-compare-share-track"
            role="img"
            aria-label={`${entry.label}: ${entry.pct}% of recorded ${scope.kind} activity`}
          >
            <span style={{ width: `${entry.pct}%` }} />
          </div>
        </div>
      ) : widget?.kind === 'trend' ? (
        <TrendChart weekly={data.weekly} />
      ) : widget?.kind === 'stat' ? (
        <StatCallout cacheHitRatePct={data.cacheHitRatePct} caption="Cache hit rate" />
      ) : widget?.kind === 'provider' ? (
        <MixBar
          title="Provider mix"
          entries={data.providerMix}
          ariaLabel={`Provider mix: ${data.providerMix.map((item) => `${item.label} ${item.pct}%`).join(', ')}`}
        />
      ) : widget?.kind === 'model' ? (
        <MixBar
          title="Model mix"
          entries={data.modelMix}
          ariaLabel={`Model mix: ${data.modelMix.map((item) => `${item.label} ${item.pct}%`).join(', ')}`}
        />
      ) : (
        <p className="muted">No comparable metric is available.</p>
      )}
      <footer className="insights-compare-provenance">
        <span>Provenance: {scope.source}</span>
        <span>{scope.sourceDetail}</span>
        <code data-testid="insights-compare-source-id">{scope.sourceID}</code>
      </footer>
    </article>
  );
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
  const [isComparing, setIsComparing] = useState(false);
  const [selectedCompareIDs, setSelectedCompareIDs] = useState<string[]>([]);
  const selectedID = workspace.selectedWidgetID;
  const layout = workspace.layout;
  const selected = widgets.find((widget) => widget.id === selectedID) ?? widgets[0];
  const qualitative = resolveQualitativeCapability(data);
  const compareOptions = useMemo(
    () => compareScopesFor(data, widgets, evidence),
    [data, evidence, widgets]
  );
  const compareOptionFingerprint = compareOptions.map((scope) => scope.id).join('|');
  const selectedCompareScopes = useMemo(() => {
    const byID = new Map(compareOptions.map((scope) => [scope.id, scope]));
    return selectedCompareIDs
      .map((scopeID) => byID.get(scopeID))
      .filter((scope): scope is InsightCompareScope => Boolean(scope));
  }, [compareOptions, selectedCompareIDs]);

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

  useEffect(() => {
    // A refreshed response may remove a provider/model. Never leave a stale
    // selection rendered as if it were still backed by the current source.
    const available = new Set(compareOptions.map((scope) => scope.id));
    setSelectedCompareIDs((current) => {
      const next = current.filter((scopeID) => available.has(scopeID)).slice(0, 3);
      return next.length === current.length && next.every((scopeID, index) => scopeID === current[index])
        ? current
        : next;
    });
  }, [compareOptionFingerprint]);

  function selectWidget(widgetID: string): void {
    if (!widgetIDs.includes(widgetID)) return;
    setWorkspace((current) => ({ ...current, selectedWidgetID: widgetID }));
  }

  function setLayout(nextLayout: InsightsCanvasLayout): void {
    setWorkspace((current) => ({ ...current, layout: nextLayout }));
  }

  function toggleCompareScope(scopeID: string): void {
    if (!compareOptions.some((scope) => scope.id === scopeID)) return;
    setSelectedCompareIDs((current) => {
      if (current.includes(scopeID)) return current.filter((id) => id !== scopeID);
      if (current.length >= 3) return current;
      return [...current, scopeID];
    });
  }

  function toggleCompareMode(): void {
    if (isComparing) {
      setIsComparing(false);
      return;
    }
    if (compareOptions.length === 0) return;
    setIsComparing(true);
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
          <strong>{isComparing ? 'Compare scopes' : 'Usage observatory'}</strong>
        </div>
        <p className="insights-library-copy">
          {isComparing
            ? 'Select up to three verified providers, models, or widgets for side-by-side review.'
            : 'Select a panel to inspect its recorded evidence and follow up in chat.'}
        </p>
        {isComparing ? (
          <section className="insights-compare-picker" aria-label="Compare scope picker">
            {compareOptions.length > 0 ? (
              <div role="group" aria-label="Compare up to three scopes">
                {compareOptions.map((scope) => {
                  const selectedForCompare = selectedCompareIDs.includes(scope.id);
                  return (
                    <button
                      type="button"
                      key={scope.id}
                      className={selectedForCompare ? 'insights-canvas-item is-selected' : 'insights-canvas-item'}
                      aria-pressed={selectedForCompare}
                      aria-label={compareScopeControlLabel(scope)}
                      disabled={!selectedForCompare && selectedCompareIDs.length >= 3}
                      onClick={() => toggleCompareScope(scope.id)}
                    >
                      <span>{scope.label}</span>
                      <small>{compareScopeKindLabel(scope)}</small>
                    </button>
                  );
                })}
              </div>
            ) : (
              <p className="insights-compare-empty" role="status">
                No verified provider, model, or widget entries are available for comparison.
              </p>
            )}
            {compareOptions.length > 0 ? (
              <p className="insights-compare-limit" aria-live="polite">
                {selectedCompareScopes.length} of 3 selected
              </p>
            ) : null}
          </section>
        ) : (
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
        )}
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
            <button
              type="button"
              className="secondary"
              aria-pressed={isComparing}
              aria-label={isComparing ? 'Exit compare' : 'Compare'}
              title={!isComparing && compareOptions.length === 0 ? 'No verified entries are available for comparison' : undefined}
              disabled={!isComparing && compareOptions.length === 0}
              onClick={toggleCompareMode}
            >
              Compare
            </button>
            <button type="button" className="secondary" onClick={() => setShowAudit(true)} aria-haspopup="dialog">
              Audit
            </button>
            <button type="button" className="secondary" onClick={onRefresh} aria-label="Refresh insights">
              Refresh
            </button>
          </div>
        </header>

        {isComparing ? (
          <section className="insights-compare-view" aria-label="Insights comparison">
            <div className="insights-compare-view-heading">
              <div>
                <span className="insights-eyebrow">Compare</span>
                <h3>Side-by-side comparison</h3>
                <p>Select up to three scopes from the canvas library.</p>
              </div>
              <span className="insights-compare-count" aria-live="polite">
                {selectedCompareScopes.length} / 3
              </span>
            </div>
            {selectedCompareScopes.length > 0 ? (
              <div className="insights-compare-grid">
                {selectedCompareScopes.map((scope) => (
                  <InsightCompareColumn
                    key={scope.id}
                    scope={scope}
                    data={data}
                    onRemove={() => toggleCompareScope(scope.id)}
                  />
                ))}
              </div>
            ) : (
              <div className="insights-compare-empty insights-compare-empty--main" role="status">
                <strong>Pick up to three scopes to compare</strong>
                <span>Choose a provider, model, or widget from the canvas library.</span>
              </div>
            )}
          </section>
        ) : (
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
        )}

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
            {qualitative.analysis ? (
              <section className="insights-qualitative-brief" aria-label="Daemon qualitative brief">
                <span className="insights-eyebrow">Daemon brief · {qualitative.analysis.modelDisplayName}</span>
                <p>{qualitative.analysis.executiveSummary}</p>
                <InsightsCitationChips
                  citations={qualitative.analysis.citations}
                  label="Analysis evidence"
                  onOpen={(citation) => onFollowUp(insightsCitationPrompt(citation))}
                />
                {qualitative.analysis.findings.length > 0 ? (
                  <ul className="insights-qualitative-findings">
                    {qualitative.analysis.findings.slice(0, 3).map((finding) => (
                      <li key={finding.id}>
                        <strong>{finding.title}</strong>
                        <span>{finding.whyItMatters}</span>
                        <span>{finding.recommendedAction}</span>
                        <InsightsCitationChips
                          citations={finding.evidence}
                          label={`Evidence for ${finding.title}`}
                          onOpen={(citation) => onFollowUp(insightsCitationPrompt(citation))}
                        />
                      </li>
                    ))}
                  </ul>
                ) : null}
              </section>
            ) : null}
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
