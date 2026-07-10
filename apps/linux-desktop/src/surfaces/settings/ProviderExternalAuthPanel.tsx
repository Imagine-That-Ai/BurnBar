import { useEffect, useMemo, useRef } from 'react';
import { Banner } from '../../components/Banner.js';
import type { ProviderExternalAuthFlowSnapshot } from '../../tauriBridge.js';
import { useProviderExternalAuthStore } from '../../state/providerExternalAuthStore.js';
import { SettingGroup } from './SettingGroup.js';
import './provider-external-auth.css';

function isActive(snapshot: ProviderExternalAuthFlowSnapshot): boolean {
  return snapshot.state === 'launching'
    || snapshot.state === 'awaiting_user'
    || snapshot.state === 'verifying';
}

function isFailure(snapshot: ProviderExternalAuthFlowSnapshot): boolean {
  return snapshot.state === 'failed' || snapshot.state === 'timed_out';
}

function statusCopy(
  snapshot: ProviderExternalAuthFlowSnapshot,
  busy: 'loading' | 'starting' | 'cancelling' | undefined
): string {
  if (busy === 'starting') return `Opening ${snapshot.cliDisplayName} login...`;
  if (busy === 'cancelling') return `Cancelling ${snapshot.cliDisplayName} sign-in...`;
  if (snapshot.problem?.message) return snapshot.problem.message;
  switch (snapshot.state) {
    case 'launching':
      return `Opening ${snapshot.cliDisplayName} login...`;
    case 'awaiting_user':
      return `Terminal opened. Finish ${snapshot.cliDisplayName} sign-in there. OpenBurnBar will verify the account when the command exits.`;
    case 'verifying':
      return `Verifying the local ${snapshot.cliDisplayName} account...`;
    case 'succeeded':
      return snapshot.accountDescription
        ? `Connected as ${snapshot.accountDescription}. Quota will refresh automatically.`
        : `${snapshot.cliDisplayName} is connected. Quota will refresh automatically.`;
    case 'cancelled':
      return `${snapshot.cliDisplayName} sign-in was cancelled. No account was changed.`;
    case 'timed_out':
      return `${snapshot.cliDisplayName} sign-in timed out before verification completed.`;
    case 'failed':
      return `${snapshot.cliDisplayName} sign-in did not complete.`;
    case 'idle':
    default:
      if (snapshot.availability === 'unavailable' || !snapshot.cliInstalled) {
        return `${snapshot.cliDisplayName} is not installed or cannot be launched.`;
      }
      return snapshot.connected
        ? `${snapshot.cliDisplayName} is connected${snapshot.accountDescription ? ` as ${snapshot.accountDescription}` : ''}.`
        : `Use the installed ${snapshot.cliDisplayName} to sign in. Credentials stay outside the desktop renderer.`;
  }
}

function shouldFocus(state: ProviderExternalAuthFlowSnapshot['state']): boolean {
  return state === 'awaiting_user'
    || state === 'succeeded'
    || state === 'failed'
    || state === 'cancelled'
    || state === 'timed_out';
}

export function ProviderExternalAuthPanel({ providerID }: { providerID: string }) {
  const snapshot = useProviderExternalAuthStore((state) => state.snapshots[providerID]);
  const busy = useProviderExternalAuthStore((state) => state.busy[providerID]);
  const error = useProviderExternalAuthStore((state) => state.errors[providerID]);
  const load = useProviderExternalAuthStore((state) => state.load);
  const start = useProviderExternalAuthStore((state) => state.start);
  const cancel = useProviderExternalAuthStore((state) => state.cancel);
  const anotherFlowActive = useProviderExternalAuthStore((state) =>
    Object.entries(state.snapshots).some(([id, value]) => id !== providerID && value && isActive(value))
  );
  const headingRef = useRef<HTMLHeadingElement>(null);
  const previousState = useRef<ProviderExternalAuthFlowSnapshot['state'] | undefined>(undefined);

  useEffect(() => {
    void load(providerID);
  }, [load, providerID]);

  useEffect(() => {
    const nextState = snapshot?.state;
    if (nextState && nextState !== previousState.current && shouldFocus(nextState)) {
      headingRef.current?.focus();
    }
    previousState.current = nextState;
  }, [snapshot?.state]);

  const copy = useMemo(() => snapshot ? statusCopy(snapshot, busy) : '', [busy, snapshot]);

  if (!snapshot) {
    return null;
  }

  if (
    snapshot.problem?.code === 'unsupported_provider'
    || snapshot.problem?.code === 'unsupported_auth_method'
  ) {
    return null;
  }

  const hasBrowserMethod = Boolean(
    snapshot.authMethodId && snapshot.authMethodDisplayName && snapshot.cliDisplayName
  );
  if (!hasBrowserMethod) return null;

  const active = isActive(snapshot);
  const unavailable = snapshot.availability === 'unavailable' || !snapshot.cliInstalled;
  const actionBusy = Boolean(busy) || active;
  const startDisabled = unavailable || actionBusy || anotherFlowActive;
  const startLabel = busy === 'starting'
    ? 'Opening...'
    : snapshot.state === 'failed' || snapshot.state === 'cancelled' || snapshot.state === 'timed_out'
      ? 'Try again'
      : snapshot.connected || snapshot.state === 'succeeded'
        ? `Reconnect ${snapshot.cliDisplayName}`
        : snapshot.authMethodDisplayName;

  return (
    <SettingGroup title="Local CLI Sign-In" sectionHeader hideTitle>
      <div
        className="provider-external-auth"
        data-auth-state={snapshot.state}
        aria-busy={Boolean(busy) || snapshot.state === 'launching' || snapshot.state === 'verifying'}
      >
        <span className="provider-external-auth-icon" aria-hidden="true">↗</span>
        <div className="provider-external-auth-copy">
          <h4 ref={headingRef} tabIndex={-1}>{snapshot.authMethodDisplayName}</h4>
          <p className="muted" role={isFailure(snapshot) ? 'alert' : undefined}>{copy}</p>
          {anotherFlowActive && !active ? (
            <p className="muted provider-external-auth-note">
              Finish or cancel the active provider sign-in before starting another.
            </p>
          ) : null}
          {error ? (
            <Banner tone="degraded" role={isFailure(snapshot) ? 'alert' : 'status'}>
              {error}
            </Banner>
          ) : null}
        </div>
        <div className="provider-external-auth-actions">
          {active ? (
            <button
              type="button"
              className="ghost"
              disabled={!snapshot.flowId || busy === 'cancelling'}
              onClick={() => snapshot.flowId && void cancel(providerID, snapshot.flowId)}
            >
              {busy === 'cancelling' ? 'Cancelling...' : 'Cancel sign-in'}
            </button>
          ) : (
            <button
              type="button"
              className="primary"
              disabled={startDisabled}
              onClick={() => void start(providerID, snapshot.authMethodId)}
            >
              {unavailable ? `${snapshot.cliDisplayName} unavailable` : startLabel}
            </button>
          )}
          {!active ? (
            <button
              type="button"
              className="ghost"
              disabled={busy === 'loading'}
              onClick={() => void load(providerID)}
            >
              Refresh
            </button>
          ) : null}
        </div>
        <span className="visually-hidden" role="status" aria-live="polite" aria-atomic="true">
          {copy}
        </span>
      </div>
    </SettingGroup>
  );
}
