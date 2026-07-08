import type { MercuryActiveSession } from '../../tauriBridge.js';
import type { MercuryStageEvent } from '../../state/mediaStore.js';

const STEPS: MercuryActiveSession['state'][] = ['staged', 'connecting', 'active', 'ended'];

function kindLabel(kind: MercuryActiveSession['kind']): string {
  switch (kind) {
    case 'file':
      return 'File transfer';
    case 'call':
      return 'Call';
    case 'screen-share':
      return 'Screen share';
  }
}

function stepLabel(step: MercuryActiveSession['state']): string {
  switch (step) {
    case 'staged':
      return 'Staged';
    case 'connecting':
      return 'Connecting';
    case 'active':
      return 'Active';
    case 'ended':
      return 'Ended';
  }
}

export function SessionStatusCard({
  session,
  events
}: {
  session: MercuryActiveSession;
  events: MercuryStageEvent[];
}) {
  const observed = new Set(events.map((event) => event.state));
  return (
    <section className={`p12-session-card ${session.state === 'connecting' ? 'is-connecting' : ''}`} aria-live="polite">
      <div className="p12-session-head">
        <span className="p12-kind-badge">{kindLabel(session.kind)}</span>
        <span className="p12-peer">{session.peer}</span>
      </div>
      <p className="p12-phase-line">Phase: {stepLabel(session.state)}</p>
      <ol className="p12-stage-rail" aria-label="Mercury media session timeline">
        {STEPS.map((step) => {
          const current = step === session.state;
          const complete = observed.has(step);
          return (
            <li key={step} className={current ? 'current' : complete ? 'complete' : ''} aria-current={current ? 'step' : undefined}>
              <span className="p12-stage-dot" aria-hidden="true" />
              <span>{stepLabel(step)}</span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}
