import { useState } from 'react';
import type { SessionEntry, SessionReplayResult } from '../../tauriBridge.js';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  formatAbsoluteTime,
  formatCostUsd,
  formatTokens,
  sessionDurationLabel
} from './sessionFormat.js';

export function SessionDetail({ session, detailId }: { session: SessionEntry; detailId: string }) {
  const glyph = PROVIDER_GLYPHS.find((g) => g.id === session.provider);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const [body, setBody] = useState<string | null>(null);
  const [bodyLoading, setBodyLoading] = useState(false);
  const [bodyError, setBodyError] = useState<string | null>(null);
  const [resumeLoading, setResumeLoading] = useState(false);
  const [resumeStatus, setResumeStatus] = useState<string | null>(null);
  // Usage-row IDs are not durable conversation identities. Never pass the
  // display/fallback ID to replay or resume: the daemon may interpret it as a
  // different provider session or reject it ambiguously.
  const replayID = session.sourceID?.trim() || null;
  const sourceIdentityUnavailable = !replayID && !fixtureMode;
  const bodyActionTitle = replayID
    ? 'Load the persisted session body'
    : fixtureMode
      ? 'Unavailable until the live daemon and indexed database are connected'
      : 'Unavailable without a verified daemon source identity';
  const resumeActionTitle = replayID
    ? 'Resume the persisted session'
    : fixtureMode
      ? 'Unavailable until the live daemon and indexed database are connected'
      : 'Unavailable without a verified daemon source identity';

  const renderReplayError = (result: SessionReplayResult): string => {
    if (result.errorCode === 'session_not_found') {
      return result.errorRecovery ?? 'The persisted session is no longer available.';
    }
    if (result.errorCode === 'ambiguous_session') {
      return result.errorRecovery ?? 'This session identifier is ambiguous; use the composite identifier.';
    }
    return result.errorRecovery ?? 'The daemon could not load this persisted session.';
  };

  const loadBody = async () => {
    setBodyError(null);
    setResumeStatus(null);
    if (fixtureMode) {
      setBodyError('Session body is unavailable until the live daemon and indexed database are connected.');
      return;
    }
    if (!replayID) {
      setBodyError('Session body is unavailable because this daemon row has no verified source identity.');
      return;
    }
    if (!bridge?.sessionReplay) {
      setBodyError('Session body is unavailable until the live daemon and indexed database are connected.');
      return;
    }
    setBodyLoading(true);
    try {
      const result = await bridge.sessionReplay(replayID);
      if (result.kind === 'error' || result.errorCode) {
        setBody(null);
        setBodyError(renderReplayError(result));
      } else if (!result.briefingMD) {
        setBody(null);
        setBodyError('No persisted session body is available for this row.');
      } else {
        setBody(result.briefingMD);
      }
    } catch (error) {
      setBody(null);
      setBodyError(error instanceof Error ? error.message : 'Session body request failed.');
    } finally {
      setBodyLoading(false);
    }
  };

  const resume = async () => {
    setBodyError(null);
    setResumeStatus(null);
    if (fixtureMode) {
      setResumeStatus('Resume is unavailable until the live daemon and indexed database are connected.');
      return;
    }
    if (!replayID) {
      setResumeStatus('Resume is unavailable because this daemon row has no verified source identity.');
      return;
    }
    if (!bridge?.sessionResume) {
      setResumeStatus('Resume is unavailable until the live daemon and indexed database are connected.');
      return;
    }
    setResumeLoading(true);
    try {
      const result = await bridge.sessionResume(replayID);
      if (result.kind === 'error' || result.errorCode) {
        setResumeStatus(renderReplayError(result));
      } else if (result.pid) {
        setResumeStatus(`Resume requested (process ${result.pid}).`);
      } else if (result.kind === 'native') {
        setResumeStatus('Native session resume requested.');
      } else {
        setResumeStatus('Session handoff requested.');
      }
    } catch (error) {
      setResumeStatus(error instanceof Error ? error.message : 'Session resume request failed.');
    } finally {
      setResumeLoading(false);
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
        <div className="fact">
          <dt>Source identity</dt>
          <dd className="mono">{session.sourceID ?? 'Unavailable from daemon row'}</dd>
        </div>
        {session.projectName ? (
          <div className="fact">
            <dt>Project</dt>
            <dd>{session.projectName}</dd>
          </div>
        ) : null}
      </dl>
      <div className="activity-session-actions" aria-label="Persisted session actions">
        <button
          type="button"
          className="ghost"
          onClick={() => void loadBody()}
          disabled={bodyLoading || sourceIdentityUnavailable}
          title={bodyActionTitle}
        >
          {bodyLoading ? 'Loading body...' : body ? 'Reload session body' : 'Load session body'}
        </button>
        <button
          type="button"
          className="ghost"
          onClick={() => void resume()}
          disabled={resumeLoading || sourceIdentityUnavailable}
          title={resumeActionTitle}
        >
          {resumeLoading ? 'Resuming...' : 'Resume session'}
        </button>
      </div>
      {sourceIdentityUnavailable ? (
        <p className="activity-session-status" role="status">
          Body and resume are unavailable because this row has no verified daemon source identity.
        </p>
      ) : null}
      <p className="activity-session-trust muted">
        Historical body is read from the daemon's indexed conversation store and rendered as untrusted text.
      </p>
      {bodyError ? (
        <p className="activity-session-error" role="alert">
          {bodyError}
        </p>
      ) : null}
      {resumeStatus ? (
        <p className="activity-session-status" role="status" aria-live="polite">
          {resumeStatus}
        </p>
      ) : null}
      {body ? (
        <div className="activity-session-body" aria-label="Persisted session body">
          <pre>{body}</pre>
        </div>
      ) : null}
    </div>
  );
}
