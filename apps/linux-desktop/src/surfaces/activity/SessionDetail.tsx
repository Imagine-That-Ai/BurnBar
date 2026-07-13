import { useEffect, useState } from 'react';
import type { SessionDetailResult, SessionEntry, SessionResumeResult } from '../../tauriBridge.js';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  formatAbsoluteTime,
  formatCostUsd,
  formatTokens,
  sessionDurationLabel
} from './sessionFormat.js';

type DetailLoadState =
  | { status: 'loading' }
  | { status: 'ready'; result: SessionDetailResult }
  | { status: 'unavailable'; message: string }
  | { status: 'error'; message: string };

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'The daemon did not return session excerpts.';
}

function resumeMessage(result: SessionResumeResult): string {
  if (result.kind === 'spawned') {
    const target = result.targetHarness ? ` in ${result.targetHarness}` : '';
    return `Session resumed${target}${result.pid ? ` (process ${result.pid})` : ''}.`;
  }
  if (result.kind === 'ported' || result.kind === 'native') {
    return result.note ?? 'The daemon prepared a resume action.';
  }
  return result.errorRecovery ?? 'The daemon could not resume this session.';
}

export function SessionDetail({ session, detailId }: { session: SessionEntry; detailId: string }) {
  const bridge = useShellStore((s) => s.bridge);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const [detail, setDetail] = useState<DetailLoadState>({ status: 'loading' });
  const [resumeBusy, setResumeBusy] = useState(false);
  const [resumeStatus, setResumeStatus] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setResumeStatus(null);

    if (session.bodySnippet) {
      setDetail({
        status: 'ready',
        result: {
          sessionID: session.sessionID ?? session.id,
          indexed: true,
          excerpts: [
            {
              id: `${session.id}-snippet`,
              sourceID: session.sourceID ?? session.id,
              sourceKind: session.sourceKind ?? 'indexed transcript',
              title: session.title,
              snippet: session.bodySnippet,
              provider: session.provider,
              projectName: session.projectName
            }
          ]
        }
      });
      return () => {
        cancelled = true;
      };
    }

    if (fixtureMode) {
      setDetail({
        status: 'unavailable',
        message: 'Transcript body is unavailable in fixture mode; connect the daemon for indexed excerpts.'
      });
      return () => {
        cancelled = true;
      };
    }

    if (!bridge?.sessionDetail) {
      setDetail({
        status: 'unavailable',
        message: 'The daemon does not expose indexed transcript detail in this session.'
      });
      return () => {
        cancelled = true;
      };
    }

    setDetail({ status: 'loading' });
    void bridge.sessionDetail(session.sessionID ?? session.id).then(
      (result) => {
        if (!cancelled) {
          setDetail(
            result.indexed
              ? { status: 'ready', result }
              : {
                  status: 'unavailable',
                  message:
                    result.degradedMessage ??
                    'No indexed transcript body is available for this session.'
                }
          );
        }
      },
      (error) => {
        if (!cancelled) setDetail({ status: 'error', message: errorMessage(error) });
      }
    );

    return () => {
      cancelled = true;
    };
  }, [bridge, fixtureMode, session]);

  const glyph = PROVIDER_GLYPHS.find((g) => g.id === session.provider);
  const sessionID = session.sessionID ?? session.id;
  const canResume = Boolean(!fixtureMode && session.sessionID && bridge?.sessionResume);

  const resume = async () => {
    if (!canResume || !bridge?.sessionResume || !session.sessionID) return;
    setResumeBusy(true);
    setResumeStatus(null);
    try {
      const result = await bridge.sessionResume(session.sessionID);
      if (result.kind === 'error' || result.kind === 'capability_absent') {
        setResumeStatus(resumeMessage(result));
      } else {
        setResumeStatus(resumeMessage(result));
      }
    } catch (error) {
      setResumeStatus(errorMessage(error));
    } finally {
      setResumeBusy(false);
    }
  };

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
          <dd className="mono tabular-nums">
            {session.searchHit || session.tokenTotalAvailable === false
              ? 'Token total unavailable'
              : formatTokens(session.tokens)}
          </dd>
        </div>
        {session.inputTokens !== undefined || session.outputTokens !== undefined ? (
          <div className="fact">
            <dt>Token breakdown</dt>
            <dd className="mono tabular-nums">
              {session.inputTokens !== undefined ? `in ${formatTokens(session.inputTokens)}` : null}
              {session.inputTokens !== undefined && session.outputTokens !== undefined ? ' · ' : null}
              {session.outputTokens !== undefined ? `out ${formatTokens(session.outputTokens)}` : null}
            </dd>
          </div>
        ) : null}
        <div className="fact">
          <dt>Cost</dt>
          <dd className="mono tabular-nums">
            {session.searchHit || session.costAvailable === false
              ? 'Cost unavailable'
              : formatCostUsd(session.costUsd)}
          </dd>
        </div>
        <div className="fact">
          <dt>Started</dt>
          <dd className="mono">{session.startedAt ? formatAbsoluteTime(session.startedAt) : 'Date unavailable'}</dd>
        </div>
        <div className="fact">
          <dt>Duration (approx.)</dt>
          <dd>{session.startedAt ? sessionDurationLabel(session.startedAt) : '—'}</dd>
        </div>
        {session.projectName ? (
          <div className="fact">
            <dt>Project</dt>
            <dd>{session.projectName}</dd>
          </div>
        ) : null}
        <div className="fact">
          <dt>Session id</dt>
          <dd className="mono">{sessionID}</dd>
        </div>
      </dl>

      <section className="activity-transcript" aria-labelledby={`${detailId}-transcript-title`}>
        <div className="activity-detail-heading">
          <h3 id={`${detailId}-transcript-title`}>Indexed transcript</h3>
          <span className="muted">daemon.search.query</span>
        </div>
        {detail.status === 'loading' ? <p className="muted">Loading indexed excerpts…</p> : null}
        {detail.status === 'error' ? (
          <p className="activity-capability activity-capability--error" role="alert">
            {detail.message}
          </p>
        ) : null}
        {detail.status === 'unavailable' ? (
          <p className="activity-capability" role="status">
            {detail.message}
          </p>
        ) : null}
        {detail.status === 'ready' ? (
          <ol className="activity-transcript-list">
            {detail.result.excerpts.map((excerpt) => (
              <li key={excerpt.id} className="activity-transcript-excerpt">
                <p className="activity-transcript-title">{excerpt.title}</p>
                <p className="activity-transcript-snippet">{excerpt.snippet || 'Indexed hit has no displayable excerpt.'}</p>
                <p className="muted activity-transcript-source">
                  {excerpt.sourceKind} · {excerpt.sourceID}
                </p>
              </li>
            ))}
          </ol>
        ) : null}
      </section>

      <div className="activity-detail-actions">
        <button
          type="button"
          className="primary"
          disabled={!canResume || resumeBusy}
          title={canResume ? 'Ask the daemon to resume this session.' : 'Resume requires a daemon session id and the canonical run.resume capability.'}
          onClick={() => void resume()}
        >
          {resumeBusy ? 'Resuming…' : canResume ? 'Resume session' : 'Resume unavailable'}
        </button>
        <button
          type="button"
          disabled
          title="The daemon does not expose a canonical session export RPC."
        >
          Export unavailable
        </button>
        {resumeStatus ? (
          <p className="activity-action-status" role="status">
            {resumeStatus}
          </p>
        ) : null}
      </div>
    </div>
  );
}
