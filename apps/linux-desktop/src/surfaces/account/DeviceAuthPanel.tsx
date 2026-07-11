import { useEffect, useRef, useState } from 'react';
import { Banner } from '../../components/Banner.js';
import { useAccountStore } from '../../state/accountStore.js';

function expiryLabel(expiresAt: string): string {
  const date = new Date(expiresAt);
  if (!Number.isFinite(date.getTime())) return 'This code expires shortly.';
  return `Code expires at ${new Intl.DateTimeFormat(undefined, {
    hour: 'numeric',
    minute: '2-digit'
  }).format(date)}.`;
}

export function DeviceAuthPanel({ compact = false }: { compact?: boolean }) {
  const phase = useAccountStore((state) => state.authPhase);
  const session = useAccountStore((state) => state.authSession);
  const authError = useAccountStore((state) => state.authError);
  const browserError = useAccountStore((state) => state.browserError);
  const start = useAccountStore((state) => state.startDeviceAuth);
  const reopen = useAccountStore((state) => state.reopenDeviceAuth);
  const cancel = useAccountStore((state) => state.cancelDeviceAuth);
  const reset = useAccountStore((state) => state.resetAuthAttempt);
  const [copied, setCopied] = useState(false);
  const phaseHeading = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    if (
      phase === 'pending' ||
      phase === 'expired' ||
      phase === 'error' ||
      phase === 'capability-absent' ||
      phase === 'cancelled'
    ) {
      phaseHeading.current?.focus();
    }
  }, [phase]);

  const copyCode = async () => {
    if (!session) return;
    try {
      await navigator.clipboard.writeText(session.userCode);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2_000);
    } catch {
      setCopied(false);
    }
  };

  if (phase === 'starting') {
    return (
      <section
        className={`device-auth-panel${compact ? ' device-auth-panel--compact' : ''}`}
        aria-busy="true"
        aria-live="polite"
        role="status"
      >
        <h3>Starting secure browser sign-in</h3>
        <p className="muted">The daemon is creating a short-lived code. Credentials never enter this app.</p>
      </section>
    );
  }

  if ((phase === 'pending' || phase === 'cancelling') && session) {
    return (
      <section
        className={`device-auth-panel${compact ? ' device-auth-panel--compact' : ''}`}
        aria-labelledby="device-auth-title"
        aria-busy={phase === 'cancelling'}
      >
        <h3 id="device-auth-title" ref={phaseHeading} tabIndex={-1}>Finish sign-in in your browser</h3>
        <p className="muted">Confirm this one-time code on BurnBar. The daemon keeps all credential material.</p>
        <div className="device-auth-code-row">
          <code className="device-auth-code" aria-label={`One-time sign-in code ${session.userCode}`}>
            {session.userCode}
          </code>
          <button type="button" className="ghost" disabled={phase === 'cancelling'} onClick={() => void copyCode()}>
            Copy code
          </button>
        </div>
        <p className="muted device-auth-expiry"><time dateTime={session.expiresAt}>{expiryLabel(session.expiresAt)}</time></p>
        {browserError ? <Banner tone="degraded" role="alert">{browserError}</Banner> : null}
        {authError ? <Banner tone="degraded" role="status">{authError}</Banner> : null}
        <div className="actions device-auth-actions">
          <button type="button" className="primary" disabled={phase === 'cancelling'} onClick={() => void reopen()}>
            Open browser again
          </button>
          <button type="button" className="ghost" disabled={phase === 'cancelling'} onClick={() => void cancel()}>
            {phase === 'cancelling' ? 'Cancelling…' : 'Cancel sign-in'}
          </button>
        </div>
        <span className="visually-hidden" aria-live="polite">{copied ? 'Sign-in code copied' : ''}</span>
      </section>
    );
  }

  if (phase === 'expired' || phase === 'error' || phase === 'capability-absent' || phase === 'cancelled') {
    const heading = phase === 'expired'
      ? 'Sign-in code expired'
      : phase === 'cancelled'
        ? 'Sign-in cancelled'
        : phase === 'capability-absent'
          ? 'Browser sign-in unavailable'
          : 'Sign-in needs attention';
    return (
      <section
        className={`device-auth-panel${compact ? ' device-auth-panel--compact' : ''}`}
        aria-labelledby="device-auth-result-title"
        aria-live="polite"
      >
        <h3 id="device-auth-result-title" ref={phaseHeading} tabIndex={-1}>{heading}</h3>
        {authError ? <Banner tone="degraded" role={phase === 'error' || phase === 'expired' ? 'alert' : 'status'}>{authError}</Banner> : null}
        {phase !== 'capability-absent' ? (
          <div className="actions device-auth-actions">
            <button type="button" className="primary" onClick={() => void start()}>Try again</button>
            <button type="button" className="ghost" onClick={reset}>Dismiss</button>
          </div>
        ) : null}
      </section>
    );
  }

  return (
    <div className={`device-auth-entry${compact ? ' device-auth-entry--compact' : ''}`}>
      <button type="button" className="primary" onClick={() => void start()}>Sign in with browser</button>
      <p className="muted">A short-lived code opens on burnbar.ai. This app never collects your password.</p>
    </div>
  );
}
