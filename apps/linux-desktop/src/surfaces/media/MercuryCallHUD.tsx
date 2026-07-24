import { useEffect, useMemo, useState } from 'react';
import type { MercuryCallState, MercuryMediaControlState } from '../../state/mediaStore.js';

function peerLabel(call: MercuryCallState): string {
  return call.peerName ?? 'Paired device';
}

function formatElapsed(startedAt?: string): string {
  if (!startedAt) return '00:00';
  const elapsed = Math.max(0, Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000));
  if (!Number.isFinite(elapsed)) return '00:00';
  const minutes = Math.floor(elapsed / 60)
    .toString()
    .padStart(2, '0');
  const seconds = (elapsed % 60).toString().padStart(2, '0');
  return `${minutes}:${seconds}`;
}

export function MercuryCallHUD({
  call,
  error,
  controlState = 'available',
  controlReason = null,
  onAccept,
  onDecline,
  onEnd
}: {
  call: MercuryCallState;
  error: string | null;
  controlState?: MercuryMediaControlState;
  controlReason?: string | null;
  onAccept: (requestId?: string) => void;
  onDecline: (requestId?: string) => void;
  onEnd: () => void;
}) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (call.phase !== 'streaming') return undefined;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [call.phase]);

  const elapsed = useMemo(() => {
    void now;
    return formatElapsed(call.startedAt);
  }, [call.startedAt, now]);

  if (controlState !== 'available' && call.phase !== 'capability-absent') {
    const isError = controlState === 'error';
    const label = controlState === 'idle' ? 'Call controls loading' : 'Call controls unavailable';
    return (
      <section
        className={`p12-call-hud ${isError ? 'is-error' : 'is-degraded'}`}
        aria-label="Mercury call controls"
        role={isError ? 'alert' : 'status'}
      >
        <span className="p12-call-kicker">{label}</span>
        <p>{controlReason ?? 'The daemon has not advertised an available Mercury control RPC.'}</p>
        {error ? <p className="p12-call-error" role="alert">{error}</p> : null}
      </section>
    );
  }

  if (call.phase === 'capability-absent') {
    return (
      <section className="p12-call-hud is-absent" aria-label="Mercury call controls">
        <span className="p12-call-kicker">Live calls unavailable</span>
        <p>The daemon does not expose the Mercury call RPCs on this build.</p>
        {error ? <p className="p12-call-error" role="alert">{error}</p> : null}
      </section>
    );
  }

  if (call.phase === 'idle') {
    return (
      <section className="p12-call-hud is-idle" aria-label="Mercury call controls">
        <span className="p12-call-kicker">Call viewer idle</span>
        <p>No incoming Mercury call. The native video viewer opens separately when a call is accepted.</p>
      </section>
    );
  }

  if (call.phase === 'ringing') {
    return (
      <section className="p12-call-hud is-ringing" aria-label="Incoming Mercury call">
        <div className="p12-call-copy" aria-live="assertive">
          <span className="p12-call-kicker">Incoming call</span>
          <h3>{peerLabel(call)}</h3>
          <p>Accept opens the native Mercury viewer window and keeps these controls in the shell.</p>
        </div>
        <div className="p12-call-actions">
          <button type="button" className="primary" onClick={() => onAccept(call.requestId)}>
            Accept
          </button>
          <button type="button" className="ghost" onClick={() => onDecline(call.requestId)}>
            Decline
          </button>
        </div>
        {error ? <p className="p12-call-error" role="alert">{error}</p> : null}
      </section>
    );
  }

  if (call.phase === 'streaming') {
    return (
      <section className="p12-call-hud is-streaming" aria-label="Active Mercury call">
        <div className="p12-call-copy" aria-live="polite">
          <span className="p12-call-kicker">Viewer streaming</span>
          <h3>{peerLabel(call)}</h3>
          <p>Elapsed {elapsed}</p>
        </div>
        <div className="p12-call-actions">
          <button type="button" className="danger" onClick={onEnd}>
            End
          </button>
        </div>
        {error ? <p className="p12-call-error" role="alert">{error}</p> : null}
      </section>
    );
  }

  return (
    <section className="p12-call-hud is-cooldown" aria-label="Mercury call controls">
      <span className="p12-call-kicker">Call ended</span>
      <p>{peerLabel(call)} disconnected. The viewer window will close when the media socket drains.</p>
      {error ? <p className="p12-call-error" role="alert">{error}</p> : null}
    </section>
  );
}
