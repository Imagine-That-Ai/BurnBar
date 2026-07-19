import { useCallback, useEffect, useState } from 'react';
import { useShellStore } from '../../state/shellStore.js';
import type {
  ComputerUseBrowserActionArguments,
  ComputerUseBrowserTool,
  ComputerUseInvokeRequest,
  ComputerUseInvokeResponse,
  ComputerUseSessionAuthorityState,
  ComputerUseSessionAuthorityStatus,
  ComputerUseSessionStartRequest
} from '../../tauriBridge.js';
import { COMPUTER_USE_SESSION_DEFAULTS } from '../../tauriBridge.js';
import { findRuntimeCapability, type RuntimeCapabilityManifest } from '../../runtimeCapabilities.js';
import './computer-use.css';

export type ComputerUseTrust = 'manual' | 'step' | 'trusted';

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

export type BrowserActionForm = {
  tool: ComputerUseBrowserTool;
  url: string;
  selector: string;
  text: string;
};

type PanicHaltResponse = {
  sessionId?: string;
  sessionID?: string;
  endedAt?: string;
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function displayInvokeResult(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  try {
    const encoded = JSON.stringify(value, null, 2);
    return encoded.length > 4_000 ? `${encoded.slice(0, 4_000)}\n...` : encoded;
  } catch {
    return 'The daemon returned an unreadable action result.';
  }
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
  requirements: readonly RunRequirement[]
): ComputerUseSessionStartRequest {
  const runId = selectedRunId.trim();
  const selectedRequirement = requirements.find(
    (item) => (item.runID ?? item.runId) === runId
  );
  const runCallId = selectedRequirement?.callID ?? selectedRequirement?.callId;
  if (!runCallId || selectedRequirement?.generation === undefined) {
    throw new Error('The selected run requirement is stale. Refresh and select it again.');
  }
  return {
    mode: 'browser' as const,
    trustMode,
    ...COMPUTER_USE_SESSION_DEFAULTS,
    clientId: 'linux-shell',
    runId,
    runCallId,
    runGeneration: selectedRequirement.generation,
    desktopOwnerAuthorizationRequest: {
      method: 'linux_desktop_owner'
    }
  };
}

const BROWSER_TOOLS: readonly ComputerUseBrowserTool[] = [
  'browser_goto',
  'browser_screenshot',
  'browser_click',
  'browser_fill'
];

export function foundationReferenceDateSeconds(now = Date.now()): number {
  return now / 1_000 - 978_307_200;
}

export function browserActionArguments(form: BrowserActionForm): ComputerUseBrowserActionArguments {
  switch (form.tool) {
    case 'browser_goto':
      return { url: form.url.trim() };
    case 'browser_click':
      return { selector: form.selector.trim() };
    case 'browser_fill':
      return { selector: form.selector.trim(), text: form.text };
    case 'browser_screenshot':
      return {};
    default: {
      const exhaustive: never = form.tool;
      return exhaustive;
    }
  }
}

export function buildComputerUseBrowserInvokeParams(
  sessionId: string,
  runId: string,
  form: BrowserActionForm,
  requirements: readonly RunRequirement[],
  requestedAt = foundationReferenceDateSeconds()
): ComputerUseInvokeRequest {
  const normalizedSessionId = sessionId.trim();
  const normalizedRunId = runId.trim();
  if (!normalizedSessionId) throw new Error('Start a Browser Computer Use session first.');
  if (!normalizedRunId) throw new Error('Select an agent run before invoking a browser action.');
  if (!BROWSER_TOOLS.includes(form.tool)) throw new Error('Unsupported Browser Computer Use action.');
  const requirement = requirements.find((item) => (item.runID ?? item.runId) === normalizedRunId);
  const callId = requirement?.callID ?? requirement?.callId;
  if (!callId || requirement?.generation === undefined) {
    throw new Error('The selected run requirement is stale. Refresh and select it again.');
  }
  if (requirement.toolKind && requirement.toolKind !== form.tool) {
    throw new Error('The selected run requirement does not match this browser action.');
  }
  const args = browserActionArguments(form);
  if (form.tool === 'browser_goto' && !args.url) throw new Error('Enter a URL before navigating.');
  if ((form.tool === 'browser_click' || form.tool === 'browser_fill') && !args.selector) {
    throw new Error('Enter a selector before targeting the browser.');
  }
  if (form.tool === 'browser_fill' && args.text === '') throw new Error('Enter text before filling the field.');
  return {
    sessionId: normalizedSessionId,
    invocation: {
      callId,
      runId: normalizedRunId,
      tool: form.tool,
      arguments: args,
      requestedBy: 'linux-shell',
      requestedAt
    }
  };
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
  const runtimeCapabilities = useShellStore((s) => s.runtimeCapabilities);
  const [probedCapabilities, setProbedCapabilities] = useState<RuntimeCapabilityManifest | null>(null);
  const [trust, setTrust] = useState<ComputerUseTrust>('step');
  const [runId, setRunId] = useState('');
  const [runRequirements, setRunRequirements] = useState<RunRequirement[]>([]);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingApproval[]>([]);
  const [browserForm, setBrowserForm] = useState<BrowserActionForm>({
    tool: 'browser_goto',
    url: 'https://',
    selector: '',
    text: ''
  });
  const [invokeResult, setInvokeResult] = useState<ComputerUseInvokeResponse | null>(null);
  const [status, setStatus] = useState<'idle' | 'busy' | 'error' | 'offline'>('idle');
  const [authorityStatus, setAuthorityStatus] = useState<ComputerUseSessionAuthorityStatus>(
    fixtureMode
      ? { state: 'authorized' }
      : { state: 'unavailable' }
  );
  const [capabilityProbeError, setCapabilityProbeError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [log, setLog] = useState<string[]>([]);

  const capabilityManifest = runtimeCapabilities ?? probedCapabilities;
  const browserCapability = capabilityManifest
    ? findRuntimeCapability(capabilityManifest, 'computer-use.browser')
    : null;
  const systemCapability = capabilityManifest
    ? findRuntimeCapability(capabilityManifest, 'computer-use.system')
    : null;
  // A native Browser Computer Use session is only safe after the daemon has
  // explicitly advertised the capability. SurfaceRouter normally enforces the
  // same boundary, but direct/stale route renders must not turn a missing or
  // failed probe into a fail-open action path.
  const browserModeAvailable = fixtureMode
    || browserCapability?.state === 'available';

  const pushLog = useCallback((line: string) => {
    setLog((prev) => [line, ...prev].slice(0, 40));
  }, []);

  useEffect(() => {
    if (fixtureMode || runtimeCapabilities) {
      setProbedCapabilities(null);
      setCapabilityProbeError(null);
      return;
    }
    // A bridge replacement invalidates any manifest returned by the previous
    // native peer. Do not briefly reuse stale capability authority while the
    // new probe is pending.
    setProbedCapabilities(null);
    if (!bridge?.runtimeCapabilities) {
      setCapabilityProbeError('The Linux runtime capability probe is unavailable.');
      return;
    }
    let cancelled = false;
    setCapabilityProbeError(null);
    void bridge.runtimeCapabilities().then((manifest) => {
      if (!cancelled) {
        setProbedCapabilities(manifest);
        setCapabilityProbeError(null);
      }
    }).catch((err) => {
      if (!cancelled) {
        setProbedCapabilities(null);
        setCapabilityProbeError(errorMessage(err));
      }
    });
    return () => {
      cancelled = true;
    };
  }, [bridge, fixtureMode, runtimeCapabilities]);

  const retireSession = useCallback((expectedSessionId: string) => {
    setSessionId((current) => clearSessionIfCurrent(current, expectedSessionId));
    setInvokeResult(null);
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
      pushLog(`Session started: ${next.sessionId} · mode=browser`);
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
  }, [pushLog]);

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
      setRunRequirements([{
        runID: 'fixture-run',
        callID: 'fixture-call',
        generation: 1,
        toolKind: 'browser_goto'
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
      && authorityStatus.state !== 'unavailable'
      && browserModeAvailable);
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
      setRunId((current) => current.trim() || 'fixture-run');
      setStatus('idle');
      pushLog('Fixture session started (browser / step).');
      return;
    }
    if (!browserModeAvailable) {
      setStatus('offline');
      setError(browserCapability?.reason ?? 'Browser Computer Use is unavailable in this Linux session.');
      return;
    }
    const normalizedRunId = runId.trim();
    if (!normalizedRunId) {
      setStatus('error');
      setError('Select an agent run before starting Browser Computer Use.');
      return;
    }
    if (!bridge?.computerUseSessionStart) {
      setStatus('offline');
      setError('Computer Use bridge unavailable.');
      return;
    }
    try {
      const params = buildComputerUseSessionStartParams(normalizedRunId, trust, runRequirements);
      applyAuthorityStatus(await bridge.computerUseSessionStart(params));
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function invokeBrowserAction() {
    setStatus('busy');
    setError(null);
    setInvokeResult(null);
    const requestedSessionId = sessionId;
    try {
      const request = buildComputerUseBrowserInvokeParams(
        requestedSessionId ?? '',
        runId,
        browserForm,
        runRequirements
      );
      if (fixtureMode) {
        const result: ComputerUseInvokeResponse = {
          sessionId: request.sessionId,
          callID: request.invocation.callId,
          status: 'awaiting_approval',
          approvalId: 'fixture-approval'
        };
        setInvokeResult(result);
        setStatus('idle');
        pushLog(`Fixture browser action queued: ${browserForm.tool}`);
        return;
      }
      if (!bridge?.computerUseInvoke) {
        setStatus('offline');
        setError('Computer Use action bridge unavailable.');
        return;
      }
      const result = await bridge.computerUseInvoke(request);
      setInvokeResult(result);
      setStatus('idle');
      pushLog(`Browser action ${result.status}: ${browserForm.tool}`);
      if (result.status === 'awaiting_approval') await refreshPending();
    } catch (err) {
      if (requestedSessionId && isAuthoritativeInvalidSessionError(err)) {
        retireSession(requestedSessionId);
      }
      setStatus('error');
      setError(errorMessage(err));
    }
  }

  async function panicHalt() {
    if (!sessionId) return;
    const requestedSessionId = sessionId;
    setStatus('busy');
    if (fixtureMode) {
      setSessionId(null);
      setInvokeResult(null);
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
      {!fixtureMode && systemCapability && systemCapability.state !== 'available' ? (
        <p className="computer-use-surface__capability" role="status">
          System Computer Use is unavailable on this Linux session. Browser actions remain the only enabled mode.
          {systemCapability.reason ? ` ${systemCapability.reason}` : ''}
        </p>
      ) : null}
      {!fixtureMode && !browserModeAvailable ? (
        <p className="computer-use-surface__capability" aria-live="polite">
          Browser Computer Use is unavailable until the Linux runtime capability probe confirms it.
          {browserCapability?.reason ? ` ${browserCapability.reason}` : ''}
          {capabilityProbeError ? ` ${capabilityProbeError}` : ''}
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
            {runRequirements.map((requirement) => {
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
        <span className="computer-use-surface__mode" aria-label="Computer Use mode">
          Browser
        </span>
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
        <div className="computer-use-card computer-use-card--action">
          <h3 id="browser-action-title">Browser action</h3>
          <p className="computer-use-action-note">
            Every action is sent to the daemon for scope, approval, panic, and audit checks. This panel never approves an action locally.
          </p>
          <div className="computer-use-action-form" aria-labelledby="browser-action-title">
            <label>
              Action
              <select
                aria-label="Browser action"
                value={browserForm.tool}
                onChange={(event) => setBrowserForm((current) => ({
                  ...current,
                  tool: event.target.value as ComputerUseBrowserTool
                }))}
                disabled={!sessionId || status === 'busy'}
              >
                <option value="browser_goto">Navigate</option>
                <option value="browser_screenshot">Screenshot</option>
                <option value="browser_click">Click</option>
                <option value="browser_fill">Type into field</option>
              </select>
            </label>
            {browserForm.tool === 'browser_goto' ? (
              <label>
                URL
                <input
                  aria-label="Browser URL"
                  type="url"
                  value={browserForm.url}
                  onChange={(event) => setBrowserForm((current) => ({ ...current, url: event.target.value }))}
                  disabled={!sessionId || status === 'busy'}
                  placeholder="https://example.com"
                />
              </label>
            ) : null}
            {browserForm.tool === 'browser_click' || browserForm.tool === 'browser_fill' ? (
              <label>
                CSS selector
                <input
                  aria-label="Browser selector"
                  value={browserForm.selector}
                  onChange={(event) => setBrowserForm((current) => ({ ...current, selector: event.target.value }))}
                  disabled={!sessionId || status === 'busy'}
                  placeholder="button[type=submit]"
                />
              </label>
            ) : null}
            {browserForm.tool === 'browser_fill' ? (
              <label>
                Text
                <input
                  aria-label="Browser text"
                  value={browserForm.text}
                  onChange={(event) => setBrowserForm((current) => ({ ...current, text: event.target.value }))}
                  disabled={!sessionId || status === 'busy'}
                  type="text"
                />
              </label>
            ) : null}
            <button
              type="button"
              className="computer-use-btn"
              onClick={() => void invokeBrowserAction()}
              disabled={!sessionId || !browserModeAvailable || status === 'busy'}
            >
              Send for approval
            </button>
          </div>
          {invokeResult ? (
            <div className="computer-use-action-result" role="status" aria-live="polite">
              <strong>Action status: {invokeResult.status}</strong>
              {invokeResult.approvalId ? <span>Approval · {invokeResult.approvalId}</span> : null}
              {invokeResult.denyReason ? <span>Reason · {invokeResult.denyReason}</span> : null}
              {displayInvokeResult(invokeResult.result) ? (
                <pre>{displayInvokeResult(invokeResult.result)}</pre>
              ) : null}
            </div>
          ) : (
            <p className="computer-use-empty">Start a session to send an explicit browser action.</p>
          )}
        </div>
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
