import { useCallback, useEffect, useState } from 'react';
import { useShellStore } from '../../state/shellStore.js';
import type {
  ComputerUseSessionAuthorityState,
  ComputerUseSessionAuthorityStatus,
  ComputerUseSessionStartRequest
} from '../../tauriBridge.js';
import { findRuntimeCapability } from '../../runtimeCapabilities.js';
import './computer-use.css';

export type ComputerUseTrust = 'manual' | 'step' | 'trusted';
export type ComputerUseMode = 'browser' | 'system';

type PendingApproval = {
  approvalId?: string;
  approvalID?: string;
  sessionId?: string;
  sessionID?: string;
  runId?: string;
  runID?: string;
  title?: string;
  message?: string;
  actionSummary?: string;
  toolKind?: string;
  trustMode?: string;
  beforeScreenshotPNGBase64?: string;
  beforeScreenshotMimeType?: string;
};

export type RunRequirement = {
  runID?: string;
  runId?: string;
  callID?: string;
  callId?: string;
  clientID?: string;
  clientId?: string;
  toolKind?: string;
  generation?: number;
};

type PanicHaltResponse = {
  sessionId?: string;
  sessionID?: string;
  endedAt?: string;
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function isAuthoritativeInvalidSessionError(error: unknown): boolean {
  const message = errorMessage(error).toLowerCase();
  return message.includes('computer use session is not active:')
    || /\b(?:unknown|invalid) computer use session\b/.test(message)
    || /\bcomputer use session (?:is )?(?:unknown|invalid|not found)\b/.test(message);
}

export function clearSessionIfCurrent(current: string | null, expected: string): string | null {
  return current === expected ? null : current;
}

export function buildComputerUseSessionStartParams(
  selectedRunId: string,
  trustMode: ComputerUseTrust,
  requirements: readonly RunRequirement[],
  mode: ComputerUseMode = 'browser'
): ComputerUseSessionStartRequest {
  const runId = selectedRunId.trim();
  const selectedRequirement = requirements.find(
    (item) => (item.runID ?? item.runId) === runId
  );
  const runCallId = selectedRequirement?.callID ?? selectedRequirement?.callId;
  if (!runCallId || selectedRequirement?.generation === undefined) {
    throw new Error('The selected run requirement is stale. Refresh and select it again.');
  }
  if (computerUseModeForTool(selectedRequirement.toolKind) !== mode) {
    throw new Error('The selected run requirement does not match the requested Computer Use mode.');
  }
  return {
    mode,
    trustMode,
    clientId: 'linux-shell',
    runId,
    runCallId,
    runGeneration: selectedRequirement.generation,
    desktopOwnerAuthorizationRequest: {
      method: 'linux_desktop_owner'
    }
  };
}

export function computerUseModeForTool(toolKind?: string): ComputerUseMode | null {
  if (toolKind?.startsWith('browser_')) return 'browser';
  if (toolKind?.startsWith('mac_input_') || toolKind === 'mac_inspect_accessibility') return 'system';
  return null;
}

const AUTHORITY_COPY: Record<ComputerUseSessionAuthorityState, string> = {
  available: 'Ready to request paired-phone Computer Use authorization.',
  waiting_phone: 'Waiting for approval on your paired phone.',
  waiting_local_owner: 'Waiting for Linux desktop-owner authorization.',
  authorized: 'Computer Use authorization complete.',
  expired: 'The Computer Use authorization request expired. Start again to retry.',
  rejected: 'The Computer Use authorization request was rejected.',
  unavailable: 'Paired phone approval is unavailable in this build.'
};

/**
 * Computer Use control surface (Phase 4 / VAL-CU-001).
 * Wires existing bridge methods only — no invented RPCs.
 */
export function ComputerUseSurface() {
  const bridge = useShellStore((s) => s.bridge);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const [trust, setTrust] = useState<ComputerUseTrust>('step');
  const [mode, setMode] = useState<ComputerUseMode>('browser');
  const [systemModeAvailable, setSystemModeAvailable] = useState(false);
  const [runId, setRunId] = useState('');
  const [runRequirements, setRunRequirements] = useState<RunRequirement[]>([]);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingApproval[]>([]);
  const [status, setStatus] = useState<'idle' | 'busy' | 'error' | 'offline'>('idle');
  const [authorityStatus, setAuthorityStatus] = useState<ComputerUseSessionAuthorityStatus>(
    fixtureMode
      ? { state: 'authorized' }
      : { state: 'unavailable' }
  );
  const [error, setError] = useState<string | null>(null);
  const [log, setLog] = useState<string[]>([]);

  const pushLog = useCallback((line: string) => {
    setLog((prev) => [line, ...prev].slice(0, 40));
  }, []);

  const retireSession = useCallback((expectedSessionId: string) => {
    setSessionId((current) => clearSessionIfCurrent(current, expectedSessionId));
    setPending((current) => current.filter(
      (item) => (item.sessionId ?? item.sessionID) !== expectedSessionId
    ));
  }, []);

  const applyAuthorityStatus = useCallback((next: ComputerUseSessionAuthorityStatus) => {
    setAuthorityStatus(next);
    if (next.state === 'authorized') {
      if (!next.sessionId) {
        setStatus('error');
        setError('Authorization completed without an active Computer Use session.');
        return;
      }
      setSessionId(next.sessionId);
      setStatus('idle');
      setError(null);
      pushLog(`Session started: ${next.sessionId} · mode=${mode}`);
      return;
    }
    if (next.state === 'waiting_phone' || next.state === 'waiting_local_owner') {
      setStatus('idle');
      setError(null);
      return;
    }
    if (next.state === 'available') {
      setStatus('idle');
      setError(null);
      return;
    }
    if (next.state === 'rejected' || next.state === 'expired') {
      setStatus('error');
      setError(next.detail ?? AUTHORITY_COPY[next.state]);
      return;
    }
    setStatus('offline');
  }, [mode, pushLog]);

  const refreshAuthorityStatus = useCallback(async () => {
    if (fixtureMode) {
      setAuthorityStatus({ state: 'authorized' });
      return;
    }
    if (!bridge?.computerUseSessionAuthorityStatus) {
      setAuthorityStatus({ state: 'unavailable' });
      return;
    }
    try {
      applyAuthorityStatus(await bridge.computerUseSessionAuthorityStatus());
    } catch (err) {
      setAuthorityStatus({ state: 'unavailable', detail: errorMessage(err) });
      setStatus('offline');
    }
  }, [applyAuthorityStatus, bridge, fixtureMode]);

  const refreshPending = useCallback(async () => {
    if (fixtureMode) {
      setPending([{
        approvalId: 'fixture-approval',
        title: 'Open the account settings page',
        message: 'The browser agent wants to navigate to the visible account settings page.',
        toolKind: 'browser_goto',
        trustMode: 'step'
      }]);
      return;
    }
    if (!bridge?.computerUseApprovalPending) {
      setStatus('offline');
      return;
    }
    try {
      const result = await bridge.computerUseApprovalPending(
        sessionId ? { sessionId } : undefined
      );
      if (sessionId && (result as { sessionActive?: unknown })?.sessionActive === false) {
        retireSession(sessionId);
        return;
      }
      const list = Array.isArray((result as { requests?: unknown[] })?.requests)
        ? ((result as { requests: unknown[] }).requests)
        : Array.isArray(result)
          ? result
          : [];
      const approvals = list as PendingApproval[];
      setPending(approvals);
      const requirements = Array.isArray((result as { runRequirements?: unknown[] })?.runRequirements)
        ? ((result as { runRequirements: unknown[] }).runRequirements as RunRequirement[])
        : [];
      setRunRequirements(requirements);
    } catch (err) {
      if (sessionId && isAuthoritativeInvalidSessionError(err)) {
        retireSession(sessionId);
      }
      setStatus('error');
      setError(errorMessage(err));
    }
  }, [bridge, fixtureMode, retireSession, sessionId]);

  const sessionAuthorityAvailable = fixtureMode
    || (Boolean(bridge?.computerUseSessionStart)
      && authorityStatus.state !== 'unavailable');
  // Action approval has a separate phone-signature contract. A session grant
  // must never be reused as authority for individual actions.
  const signedActionAuthorityAvailable = fixtureMode;

  useEffect(() => {
    void refreshPending();
  }, [refreshPending]);

  useEffect(() => {
    void refreshAuthorityStatus();
  }, [refreshAuthorityStatus]);

  useEffect(() => {
    if (fixtureMode || !bridge?.runtimeCapabilities) {
      setSystemModeAvailable(false);
      return;
    }
    let cancelled = false;
    void bridge.runtimeCapabilities().then((manifest) => {
      if (cancelled) return;
      const capability = findRuntimeCapability(manifest, 'computer-use.system');
      setSystemModeAvailable(capability?.state === 'available');
    }).catch(() => {
      if (!cancelled) setSystemModeAvailable(false);
    });
    return () => { cancelled = true; };
  }, [bridge, fixtureMode]);

  useEffect(() => {
    if (fixtureMode
      || (authorityStatus.state !== 'waiting_phone'
        && authorityStatus.state !== 'waiting_local_owner')) return;
    const poll = window.setInterval(() => void refreshAuthorityStatus(), 1_000);
    return () => window.clearInterval(poll);
  }, [authorityStatus.state, fixtureMode, refreshAuthorityStatus]);

  useEffect(() => {
    if (fixtureMode || !bridge?.computerUseApprovalPending) return;
    const poll = window.setInterval(() => void refreshPending(), 1_000);
    return () => window.clearInterval(poll);
  }, [bridge, fixtureMode, refreshPending]);

  async function startSession() {
    setStatus('busy');
    setError(null);
    if (fixtureMode) {
      setSessionId('fixture-session');
      setStatus('idle');
      pushLog('Fixture session started (browser / step).');
      return;
    }
    const normalizedRunId = runId.trim();
    if (!normalizedRunId) {
      setStatus('error');
      setError(`Select an agent run before starting ${mode === 'system' ? 'System' : 'Browser'} Computer Use.`);
      return;
    }
    if (!bridge?.computerUseSessionStart) {
      setStatus('offline');
      setError('Computer Use bridge unavailable.');
      return;
    }
    try {
      const params = buildComputerUseSessionStartParams(normalizedRunId, trust, runRequirements, mode);
      applyAuthorityStatus(await bridge.computerUseSessionStart(params));
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function panicHalt() {
    if (!sessionId) return;
    const requestedSessionId = sessionId;
    setStatus('busy');
    if (fixtureMode) {
      setSessionId(null);
      setPending([]);
      setStatus('idle');
      pushLog('Fixture panic halt.');
      return;
    }
    try {
      const result = await bridge?.computerUsePanicHalt?.({
        sessionId: requestedSessionId,
        source: 'hotkey'
      }) as PanicHaltResponse | undefined;
      const endedSessionId = result?.sessionId ?? result?.sessionID;
      if (endedSessionId === requestedSessionId && result?.endedAt) {
        retireSession(requestedSessionId);
      }
      setStatus('idle');
      pushLog('Panic halt sent.');
    } catch (err) {
      if (isAuthoritativeInvalidSessionError(err)) {
        retireSession(requestedSessionId);
      }
      setStatus('error');
      setError(errorMessage(err));
    }
  }

  async function exportAudit() {
    if (!sessionId) return;
    const requestedSessionId = sessionId;
    setStatus('busy');
    if (fixtureMode) {
      setStatus('idle');
      pushLog('Fixture audit export ready.');
      return;
    }
    try {
      await bridge?.computerUseAuditExport?.({
        sessionId: requestedSessionId,
        includeScreenshots: true,
        anchorOpenTimestamps: false
      });
      setStatus('idle');
      pushLog('Audit export requested.');
    } catch (err) {
      if (isAuthoritativeInvalidSessionError(err)) {
        retireSession(requestedSessionId);
      }
      setStatus('error');
      setError(errorMessage(err));
    }
  }

  async function respondApproval(
    decision: 'approve' | 'reject' | 'reject_and_halt',
    approvalId: string,
    approvalSessionId: string
  ) {
    setStatus('busy');
    if (fixtureMode) {
      setPending([]);
      setStatus('idle');
      pushLog(`Fixture approval ${decision}: ${approvalId}`);
      return;
    }
    try {
      await bridge?.computerUseApprovalRespond?.({
        sessionId: approvalSessionId,
        approvalId,
        decision,
        respondedBy: 'linux-shell'
      });
      setStatus('idle');
      pushLog(`Approval ${decision}: ${approvalId}`);
      await refreshPending();
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  return (
    <section className="computer-use-surface" data-state={status} aria-label="Computer Use">
      <header className="computer-use-surface__header">
        <div>
          <h2 className="computer-use-surface__title">Computer Use</h2>
          <p className="computer-use-surface__hint">
            Approval-gated automation via daemon contracts. Panic halt and audit export stay one click away.
          </p>
        </div>
        {sessionId ? (
          <span className="computer-use-surface__session" title={sessionId}>
            Session · {sessionId.slice(0, 12)}
          </span>
        ) : null}
      </header>

      {error ? (
        <p className="computer-use-surface__error" role="alert">
          {error}
        </p>
      ) : null}
      {!fixtureMode ? (
        <p
          className={`computer-use-surface__authority computer-use-surface__authority--${authorityStatus.state}`}
          role="status"
          aria-live="polite"
        >
          {authorityStatus.detail ?? AUTHORITY_COPY[authorityStatus.state]}
        </p>
      ) : null}

      <div className="computer-use-surface__controls">
        <label>
          Agent run
          <select
            value={runId}
            onChange={(event) => setRunId(event.target.value)}
            disabled={Boolean(sessionId)}
          >
            <option value="">Select a waiting run</option>
            {runRequirements.filter(
              (requirement) => computerUseModeForTool(requirement.toolKind) === mode
            ).map((requirement) => {
              const id = requirement.runID ?? requirement.runId ?? '';
              const callID = requirement.callID ?? requirement.callId;
              return (
                <option key={`${id}-${requirement.generation ?? 0}`} value={id}>
                  {id} · {requirement.toolKind ?? 'browser'}{callID ? ` · ${callID}` : ''}
                </option>
              );
            })}
            {sessionId && runId && !runRequirements.some((item) => (item.runID ?? item.runId) === runId) ? (
              <option value={runId}>{runId}</option>
            ) : null}
          </select>
        </label>
        <label>
          Mode
          <select
            aria-label="Computer Use mode"
            value={mode}
            disabled={Boolean(sessionId)}
            onChange={(event) => {
              setMode(event.target.value as ComputerUseMode);
              setRunId('');
            }}
          >
            <option value="browser">Browser</option>
            {systemModeAvailable ? <option value="system">System</option> : null}
          </select>
        </label>
        <label>
          Trust
          <select value={trust} onChange={(e) => setTrust(e.target.value as ComputerUseTrust)}>
            <option value="manual">Manual</option>
            <option value="step">Step</option>
            <option value="trusted">Trusted</option>
          </select>
        </label>
        <button
          type="button"
          className="computer-use-btn"
          onClick={() => void startSession()}
          disabled={!sessionAuthorityAvailable
            || authorityStatus.state === 'waiting_phone'
            || authorityStatus.state === 'waiting_local_owner'
            || status === 'busy'
            || Boolean(sessionId)}
        >
          Start session
        </button>
        <button
          type="button"
          className="computer-use-btn computer-use-btn--danger"
          onClick={() => void panicHalt()}
          disabled={!sessionId || status === 'busy'}
        >
          Panic halt
        </button>
        <button
          type="button"
          className="computer-use-btn"
          onClick={() => void exportAudit()}
          disabled={!sessionId || status === 'busy'}
        >
          Export audit
        </button>
        <button type="button" className="computer-use-btn" onClick={() => void refreshPending()}>
          Refresh approvals
        </button>
      </div>

      <div className="computer-use-surface__grid">
        <div className="computer-use-card">
          <h3>Pending approvals</h3>
          {pending.length === 0 ? (
            <p className="computer-use-empty">No pending Computer Use approvals.</p>
          ) : (
            <ul className="computer-use-list">
              {pending.map((item, idx) => {
                const id = item.approvalId ?? item.approvalID;
                const itemSessionId = item.sessionId ?? item.sessionID;
                const itemKey = id && itemSessionId ? `${itemSessionId}:${id}` : `invalid-${idx}`;
                const heading = item.title ?? item.actionSummary ?? item.toolKind ?? 'Invalid approval request';
                const itemRunId = item.runId ?? item.runID;
                const screenshotSource = item.beforeScreenshotPNGBase64
                  ? `data:${item.beforeScreenshotMimeType ?? 'image/png'};base64,${item.beforeScreenshotPNGBase64}`
                  : null;
                return (
                  <li key={itemKey}>
                    <span className="computer-use-approval">
                      <strong>{heading}</strong>
                      {item.message && item.message !== heading ? <span>{item.message}</span> : null}
                      <small>
                        {item.toolKind ?? 'computer_use'} · {item.trustMode ?? trust}
                        {itemRunId ? ` · run ${itemRunId}` : ''}
                        {itemSessionId ? ` · session ${itemSessionId}` : ''}{id ? ` · ${id}` : ''}
                      </small>
                      {screenshotSource ? (
                        <img
                          className="computer-use-approval__evidence"
                          src={screenshotSource}
                          alt={`Pre-action browser state for ${heading}`}
                        />
                      ) : null}
                    </span>
                    <span className="computer-use-actions">
                      <button type="button" disabled={!signedActionAuthorityAvailable || !id || !itemSessionId} aria-label={`Approve ${heading}`} onClick={() => id && itemSessionId && void respondApproval('approve', id, itemSessionId)}>
                        Approve
                      </button>
                      <button type="button" disabled={!signedActionAuthorityAvailable || !id || !itemSessionId} aria-label={`Reject ${heading}`} onClick={() => id && itemSessionId && void respondApproval('reject', id, itemSessionId)}>
                        Reject
                      </button>
                      <button type="button" disabled={!signedActionAuthorityAvailable || !id || !itemSessionId} aria-label={`Reject and halt ${heading}`} onClick={() => id && itemSessionId && void respondApproval('reject_and_halt', id, itemSessionId)}>
                        Reject + halt
                      </button>
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
        <div className="computer-use-card">
          <h3>Activity</h3>
          {log.length === 0 ? (
            <p className="computer-use-empty">Start a session to see activity.</p>
          ) : (
            <ul className="computer-use-list computer-use-list--log">
              {log.map((line, index) => (
                <li key={`${index}-${line}`}>{line}</li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  );
}
