import { useState } from 'react';
import { Banner } from '../components/Banner.js';
import { ONBOARDING_STEPS } from '../onboardingSteps.js';
import { readOnboarding, writeOnboarding } from '../onboardingStore.js';
import { selectDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import './onboarding.css';

const OPENBURNBAR_LOGO = '/provider-logos/openburnbar.png';

/**
 * Linux first-run wizard. State lives in localStorage
 * (`openburnbar.linux.onboarding.v1`) so skip/retry/resume survive restart.
 *
 * Visual language mirrors the macOS Hermes/onboarding liquid-glass plate:
 * specular glass card over the kernel backdrop, capsule step rail, and
 * interactive glass actions — never a second nested glass layer inside.
 */
export function OnboardingSurface() {
  const [ob, setOb] = useState(readOnboarding);
  const [retryMessage, setRetryMessage] = useState<string | null>(null);
  const refreshHealth = useShellStore((s) => s.refreshHealth);
  const setRoute = useShellStore((s) => s.setRoute);

  if (ob.completed) {
    return (
      <div className="onboarding-stage">
        <div className="onboarding-wizard setup-complete" role="status">
          <div className="setup-complete-mark" aria-hidden="true">
            ✓
          </div>
          <h3>Setup checklist complete</h3>
          <p>
            Linux onboarding is acknowledged. Dashboard routes remain local-only until the daemon is
            reachable.
          </p>
          <div className="actions onboarding-actions">
            <button
              type="button"
              className="onboarding-btn-primary"
              onClick={() => setRoute('overview')}
            >
              <span>Open dashboard</span>
            </button>
          </div>
        </div>
      </div>
    );
  }

  const stepIndex = Math.min(ob.step, ONBOARDING_STEPS.length - 1);
  const step = ONBOARDING_STEPS[stepIndex] ?? ONBOARDING_STEPS[0];
  const isLastStep = stepIndex === ONBOARDING_STEPS.length - 1;
  const canGoBack = stepIndex > 0;
  const progressFraction = (stepIndex + 1) / ONBOARDING_STEPS.length;

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

  const goBack = () => {
    if (!canGoBack) return;
    const next = writeOnboarding({ step: stepIndex - 1, completed: false });
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
    <div className="onboarding-stage">
      <section className="onboarding-wizard" aria-labelledby="onboarding-step-title">
        <header className="onboarding-wizard-header">
          <div className="onboarding-wizard-brand">
            <span className="onboarding-wizard-mark" aria-hidden="true">
              <img src={OPENBURNBAR_LOGO} alt="" width={18} height={18} decoding="async" />
            </span>
            <p className="onboarding-wizard-kicker">First-run setup</p>
          </div>
          <p className="step-progress">{`Step ${stepIndex + 1} of ${ONBOARDING_STEPS.length}`}</p>
        </header>

        <div
          className="onboarding-progress"
          role="progressbar"
          aria-valuemin={1}
          aria-valuemax={ONBOARDING_STEPS.length}
          aria-valuenow={stepIndex + 1}
          aria-label="Onboarding progress"
        >
          <div
            className="onboarding-progress-fill"
            style={{ width: `${Math.round(progressFraction * 100)}%` }}
          />
        </div>

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

        <div className="onboarding-step" key={stepIndex}>
          <div className="onboarding-step-meta">
            <span className="onboarding-step-glyph" aria-hidden="true">
              {step.glyph}
            </span>
            <p className="onboarding-step-index">{step.kicker}</p>
          </div>
          <h3 id="onboarding-step-title">{step.title}</h3>
          <p className="onboarding-step-body">{step.body}</p>
        </div>

        {retryMessage ? (
          <Banner tone="degraded" role="status">
            <span className="retry-feedback">{retryMessage}</span>
          </Banner>
        ) : null}

        <div className="actions onboarding-actions">
          <div className="onboarding-actions-secondary">
            {canGoBack ? (
              <button type="button" className="onboarding-btn-ghost" onClick={goBack}>
                Back
              </button>
            ) : null}
            <button type="button" className="onboarding-btn-ghost" onClick={() => void retry()}>
              Retry check
            </button>
            <button type="button" className="onboarding-btn-ghost" onClick={() => advance(true)}>
              Skip step
            </button>
          </div>
          <button type="button" className="onboarding-btn-primary" onClick={() => advance(false)}>
            <span>{isLastStep ? 'Finish setup' : 'Continue'}</span>
          </button>
        </div>
      </section>
    </div>
  );
}
