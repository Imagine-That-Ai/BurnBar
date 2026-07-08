import { useState } from 'react';
import { Banner } from '../components/Banner.js';
import { ONBOARDING_STEPS } from '../onboardingSteps.js';
import { readOnboarding, writeOnboarding } from '../onboardingStore.js';
import { selectDaemonStatusCopy, useShellStore } from '../state/shellStore.js';

/**
 * Linux first-run wizard. State lives in localStorage
 * (`openburnbar.linux.onboarding.v1`) so skip/retry/resume survive restart.
 */
export function OnboardingSurface() {
  const [ob, setOb] = useState(readOnboarding);
  const [retryMessage, setRetryMessage] = useState<string | null>(null);
  const refreshHealth = useShellStore((s) => s.refreshHealth);

  if (ob.completed) {
    return (
      <div className="setup-complete" role="status">
        <h3>Setup checklist complete</h3>
        <p>Linux onboarding is acknowledged. Dashboard routes remain local-only until the daemon is reachable.</p>
      </div>
    );
  }

  const stepIndex = Math.min(ob.step, ONBOARDING_STEPS.length - 1);
  const step = ONBOARDING_STEPS[stepIndex] ?? ONBOARDING_STEPS[0];
  const isLastStep = stepIndex === ONBOARDING_STEPS.length - 1;

  const advance = (skipped: boolean) => {
    const n = Math.min(stepIndex + 1, ONBOARDING_STEPS.length - 1);
    const next = writeOnboarding({
      ...(skipped ? { skippedSteps: [...new Set([...ob.skippedSteps, stepIndex])] } : {}),
      step: n,
      completed: isLastStep
    });
    setOb(next);
    setRetryMessage(null);
  };

  const retry = async () => {
    await refreshHealth();
    const state = useShellStore.getState();
    const status = selectDaemonStatusCopy(state);
    setRetryMessage(state.health?.ok ? 'Daemon check passed.' : `${status.label}: ${status.detail}`);
  };

  return (
    <>
      <div className="step-rail" aria-hidden="true">
        {ONBOARDING_STEPS.map((_, i) => (
          <span
            key={i}
            className={`step-dot${i === stepIndex ? ' active' : ''}${i < stepIndex ? ' done' : ''}${
              ob.skippedSteps.includes(i) ? ' skipped' : ''
            }`}
          />
        ))}
      </div>
      <p className="step-progress">{`Step ${stepIndex + 1} of ${ONBOARDING_STEPS.length}`}</p>
      <h3>{step.title}</h3>
      <p>{step.body}</p>
      {retryMessage ? (
        <Banner tone="degraded" role="status">
          <span className="retry-feedback">{retryMessage}</span>
        </Banner>
      ) : null}
      <div className="actions">
        <button type="button" className="primary" onClick={() => advance(false)}>
          {isLastStep ? 'Finish setup' : 'Continue'}
        </button>
        <button type="button" className="ghost" onClick={() => void retry()}>
          Retry check
        </button>
        <button type="button" className="ghost" onClick={() => advance(true)}>
          Skip step
        </button>
      </div>
    </>
  );
}
