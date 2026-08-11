import { useEffect, useId, useRef, useState } from 'react';
import type { SessionEntry } from '../../tauriBridge.js';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import { formatAbsoluteTime, formatCostUsd, formatRelativeTime, formatTokens } from './sessionFormat.js';
import { SessionDetail } from './SessionDetail.js';
import { ProviderLogoView } from '../../components/ProviderLogoView.js';

export type ActivityMetricMode = 'cost' | 'tokens';

export function SessionRow({
  session,
  metricMode,
  focusRevision
}: {
  session: SessionEntry;
  metricMode: ActivityMetricMode;
  focusRevision?: number;
}) {
  const [expanded, setExpanded] = useState(false);
  const detailId = useId();
  const glyph = PROVIDER_GLYPHS.find((g) => g.id === session.provider);
  const rowRef = useRef<HTMLLIElement>(null);

  useEffect(() => {
    if (focusRevision === undefined) return;
    setExpanded(true);
    const frame = window.requestAnimationFrame(() => {
      rowRef.current?.scrollIntoView?.({ block: 'center' });
      rowRef.current?.focus?.({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [focusRevision]);

  return (
    <li
      ref={rowRef}
      className="activity-row"
      tabIndex={focusRevision === undefined ? undefined : -1}
      aria-current={focusRevision === undefined ? undefined : 'true'}
    >
      <div className="activity-row-main">
        <ProviderLogoView
          id={session.provider}
          size={20}
          accent={glyph?.accent}
          className="activity-row-logo"
        />
        <span className="activity-row-title">{session.title}</span>
        <span className="activity-model-chip mono">{session.model}</span>
        <span className="activity-row-metric activity-row-metric--primary mono tabular-nums">
          {metricMode === 'cost' ? formatCostUsd(session.costUsd) : formatTokens(session.tokens)}
        </span>
        <time className="activity-row-time" dateTime={session.startedAt} title={formatAbsoluteTime(session.startedAt)}>
          {formatRelativeTime(session.startedAt)}
        </time>
        <button
          type="button"
          className="activity-row-toggle"
          aria-expanded={expanded}
          aria-controls={detailId}
          onClick={() => setExpanded((v) => !v)}
        >
          {expanded ? 'Hide details' : 'Show details'}
        </button>
      </div>
      {expanded ? <SessionDetail session={session} detailId={detailId} /> : null}
    </li>
  );
}
