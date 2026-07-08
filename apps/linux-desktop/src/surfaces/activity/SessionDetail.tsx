import type { SessionEntry } from '../../tauriBridge.js';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import {
  formatAbsoluteTime,
  formatCostUsd,
  formatTokens,
  sessionDurationLabel
} from './sessionFormat.js';

export function SessionDetail({ session, detailId }: { session: SessionEntry; detailId: string }) {
  const glyph = PROVIDER_GLYPHS.find((g) => g.id === session.provider);

  return (
    <div id={detailId} className="activity-detail" role="region" aria-label={`Details for ${session.title}`}>
      <dl className="activity-detail-grid fact-grid">
        <div className="fact">
          <dt>Provider</dt>
          <dd>{glyph?.label ?? session.provider}</dd>
        </div>
        <div className="fact">
          <dt>Model</dt>
          <dd className="mono">{session.model}</dd>
        </div>
        <div className="fact">
          <dt>Tokens</dt>
          <dd className="mono tabular-nums">{formatTokens(session.tokens)}</dd>
        </div>
        <div className="fact">
          <dt>Cost</dt>
          <dd className="mono tabular-nums">{formatCostUsd(session.costUsd)}</dd>
        </div>
        <div className="fact">
          <dt>Started</dt>
          <dd className="mono">{formatAbsoluteTime(session.startedAt)}</dd>
        </div>
        <div className="fact">
          <dt>Duration (approx.)</dt>
          <dd>{sessionDurationLabel(session.startedAt)}</dd>
        </div>
        <div className="fact">
          <dt>Session id</dt>
          <dd className="mono">{session.id}</dd>
        </div>
      </dl>
    </div>
  );
}