import { useCallback, useEffect, useState } from 'react';
import { useShellStore } from '../../state/shellStore.js';
import './computer-use.css';

export type ComputerUseMode = 'agent_watch' | 'browser' | 'system';
export type ComputerUseTrust = 'manual' | 'step' | 'trusted';

/**
 * Computer Use control surface (Phase 4 / VAL-CU-001).
 * Wires existing bridge methods only — no invented RPCs.
 */
export function ComputerUseSurface() {
  const bridge = useShellStore((s) => s.bridge);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const [mode, setMode] = useState<ComputerUseMode>('browser');
  const [trust, setTrust] = useState<ComputerUseTrust>('step');
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [pending, setPending] = useState<unknown[]>([]);
  const [status, setStatus] = useState<'idle' | 'busy' | 'error' | 'offline'>('idle');
  const [error, setError] = useState<string | null>(null);
  const [log, setLog] = useState<string[]>([]);

  const pushLog = useCallback((line: string) => {
    setLog((prev) => [line, ...prev].slice(0, 40));
  }, []);

  const refreshPending = useCallback(async () => {
    if (fixtureMode) {
      setPending([{ approvalId: 'fixture-approval', decisionRequired: true }]);
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
      const list = Array.isArray((result as { requests?: unknown[] })?.requests)
        ? ((result as { requests: unknown[] }).requests)
        : Array.isArray(result)
          ? result
          : [];
      setPending(list);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [bridge, fixtureMode, sessionId]);

  useEffect(() => {
    void refreshPending();
  }, [refreshPending]);

  async function startSession() {
    setStatus('busy');
    setError(null);
    if (fixtureMode) {
      setSessionId('fixture-session');
      setStatus('idle');
      pushLog('Fixture session started (browser / step).');
      return;
    }
    if (!bridge?.computerUseSessionStart) {
      setStatus('offline');
      setError('Computer Use bridge unavailable.');
      return;
    }
    try {
      const result = (await bridge.computerUseSessionStart({
        mode,
        trustMode: trust,
        clientId: 'linux-shell'
      })) as { sessionId?: string; sessionID?: string };
      const id = result.sessionId ?? result.sessionID ?? null;
      setSessionId(id);
      setStatus('idle');
      pushLog(`Session started: ${id ?? 'ok'} · mode=${mode} · trust=${trust}`);
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function panicHalt() {
    if (!sessionId) return;
    setStatus('busy');
    if (fixtureMode) {
      setStatus('idle');
      pushLog('Fixture panic halt.');
      return;
    }
    try {
      await bridge?.computerUsePanicHalt?.({ sessionId, source: 'hotkey' });
      setStatus('idle');
      pushLog('Panic halt sent.');
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function exportAudit() {
    if (!sessionId) return;
    setStatus('busy');
    if (fixtureMode) {
      setStatus('idle');
      pushLog('Fixture audit export ready.');
      return;
    }
    try {
      await bridge?.computerUseAuditExport?.({
        sessionId,
        includeScreenshots: true,
        anchorOpenTimestamps: false
      });
      setStatus('idle');
      pushLog('Audit export requested.');
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function respondApproval(decision: 'approve' | 'reject' | 'reject_and_halt', approvalId: string) {
    setStatus('busy');
    if (fixtureMode) {
      setPending([]);
      setStatus('idle');
      pushLog(`Fixture approval ${decision}: ${approvalId}`);
      return;
    }
    try {
      await bridge?.computerUseApprovalRespond?.({
        sessionId: sessionId ?? undefined,
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

  const systemTierC =
    mode === 'system'
      ? 'System Computer Use is compositor-dependent (portal/libei/uinput). Browser mode is fully supported; system is Tier C when blocked.'
      : null;

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
      {systemTierC ? <p className="computer-use-surface__tierc">{systemTierC}</p> : null}

      <div className="computer-use-surface__controls">
        <label>
          Mode
          <select value={mode} onChange={(e) => setMode(e.target.value as ComputerUseMode)}>
            <option value="browser">Browser</option>
            <option value="agent_watch">Agent watch</option>
            <option value="system">System (Tier C)</option>
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
        <button type="button" className="computer-use-btn" onClick={() => void startSession()} disabled={status === 'busy'}>
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
                const id =
                  (item as { approvalId?: string; approvalID?: string })?.approvalId ??
                  (item as { approvalID?: string })?.approvalID ??
                  `item-${idx}`;
                return (
                  <li key={id}>
                    <span>{id}</span>
                    <span className="computer-use-actions">
                      <button type="button" onClick={() => void respondApproval('approve', id)}>
                        Approve
                      </button>
                      <button type="button" onClick={() => void respondApproval('reject', id)}>
                        Reject
                      </button>
                      <button type="button" onClick={() => void respondApproval('reject_and_halt', id)}>
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
              {log.map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  );
}
