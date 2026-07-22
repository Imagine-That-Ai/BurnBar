import { useEffect, useState } from 'react';
import { Banner } from '../components/Banner.js';
import { ONBOARDING_STEPS } from '../onboardingSteps.js';
import {
  cacheOnboarding,
  readOnboarding,
  type LinuxOnboardingActionRequest,
  type LinuxOnboardingPrivacyChoices,
  type LinuxOnboardingSnapshot
} from '../onboardingStore.js';
import type { ConfigSnapshot, ProviderCatalog } from '../tauriBridge.js';
import { useShellStore } from '../state/shellStore.js';
import './onboarding.css';

const OPENBURNBAR_LOGO = '/provider-logos/openburnbar.png';

function isTerminal(state: LinuxOnboardingSnapshot['steps'][number]['state']): boolean {
  return state === 'verified' || state === 'acknowledged' || state === 'skipped';
}

function ProviderSetup({
  catalog,
  onStore,
  disabled,
  status
}: {
  catalog: ProviderCatalog;
  onStore: (providerID: string, label: string, apiKey: string) => Promise<void>;
  disabled: boolean;
  status: string | null;
}) {
  const [providerID, setProviderID] = useState(catalog[0]?.id ?? '');
  const [label, setLabel] = useState('Primary');
  const [apiKey, setApiKey] = useState('');
  const selected = catalog.find((entry) => entry.id === providerID) ?? catalog[0];

  useEffect(() => {
    if (!catalog.some((entry) => entry.id === providerID)) setProviderID(catalog[0]?.id ?? '');
  }, [catalog, providerID]);

  if (catalog.length === 0) {
    return (
      <section className="onboarding-provider-setup" aria-labelledby="onboarding-provider-title">
        <h4 id="onboarding-provider-title">Provider connection</h4>
        <p className="muted">The daemon returned no provider catalog. Open Settings → Providers after setup to configure a native provider.</p>
      </section>
    );
  }

  return (
    <section className="onboarding-provider-setup" aria-labelledby="onboarding-provider-title">
      <h4 id="onboarding-provider-title">Connect a provider</h4>
      <p className="muted">The key is sent once to the daemon and stored in the native Secret Service. It is never cached in the web view.</p>
      <label>
        Provider
        <select value={selected?.id ?? ''} onChange={(event) => setProviderID(event.currentTarget.value)} disabled={disabled}>
          {catalog.map((entry) => (
            <option key={entry.id} value={entry.id}>{entry.label}</option>
          ))}
        </select>
      </label>
      <p className="onboarding-provider-status muted" role="status">
        {selected?.accountLabel || 'No connected account reported by the daemon.'}
      </p>
      <label>
        Credential label
        <input value={label} onChange={(event) => setLabel(event.currentTarget.value)} disabled={disabled} autoComplete="off" />
      </label>
      <label>
        API key
        <input
          type="password"
          value={apiKey}
          onChange={(event) => setApiKey(event.currentTarget.value)}
          disabled={disabled}
          autoComplete="new-password"
          spellCheck={false}
          aria-describedby="onboarding-provider-help"
        />
      </label>
      <p id="onboarding-provider-help" className="muted">OAuth-only providers, portal consent, and unsupported provider auth remain available from their native Settings flow.</p>
      <button
        type="button"
        className="onboarding-btn-ghost"
        disabled={disabled || !selected || !apiKey.trim()}
        onClick={() => {
          if (!selected || !apiKey.trim()) return;
          void onStore(selected.id, label.trim() || 'Primary', apiKey);
          setApiKey('');
        }}
      >
        Store credential securely
      </button>
      {status ? <p className="onboarding-provider-status" role="status">{status}</p> : null}
    </section>
  );
}

/** Daemon-authoritative Linux first-run and repair workflow. */
export function OnboardingSurface() {
  const [snapshot, setSnapshot] = useState(readOnboarding);
  const [authorityReady, setAuthorityReady] = useState(false);
  const [authorityAttempt, setAuthorityAttempt] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [providerCatalog, setProviderCatalog] = useState<ProviderCatalog | null>(null);
  const [providerStatus, setProviderStatus] = useState<string | null>(null);
  const [privacyChoices, setPrivacyChoices] = useState<LinuxOnboardingPrivacyChoices>(() =>
    snapshot.privacyChoices ?? { telemetryEnabled: false, cloudSyncEnabled: false }
  );
  const bridge = useShellStore((state) => state.bridge);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const setRoute = useShellStore((state) => state.setRoute);

  useEffect(() => {
    let cancelled = false;
    if (!bridge) {
      setAuthorityReady(false);
      return () => {
        cancelled = true;
      };
    }
    setBusy(true);
    setError(null);
    void bridge.onboardingSnapshot()
      .then((next) => {
        if (cancelled) return;
        cacheOnboarding(next);
        setSnapshot(next);
        setPrivacyChoices(next.privacyChoices ?? { telemetryEnabled: false, cloudSyncEnabled: false });
        setAuthorityReady(true);
      })
      .catch((loadError: unknown) => {
        if (cancelled) return;
        setError(loadError instanceof Error ? loadError.message : String(loadError));
        setAuthorityReady(false);
      })
      .finally(() => {
        if (!cancelled) setBusy(false);
      });
    return () => {
      cancelled = true;
    };
  }, [bridge, authorityAttempt]);

  useEffect(() => {
    let cancelled = false;
    if (!bridge || snapshot.currentStepID !== 'provider_paths') {
      setProviderCatalog(null);
      return () => {
        cancelled = true;
      };
    }
    void bridge.providerCatalog()
      .then((catalog) => {
        if (!cancelled) setProviderCatalog(catalog);
      })
      .catch(() => {
        if (!cancelled) setProviderCatalog([]);
      });
    return () => {
      cancelled = true;
    };
  }, [bridge, snapshot.currentStepID]);

  const commit = (next: LinuxOnboardingSnapshot) => {
    cacheOnboarding(next);
    setSnapshot(next);
    if (next.privacyChoices) setPrivacyChoices(next.privacyChoices);
    setAuthorityReady(true);
    setError(null);
  };

  const perform = async (request: LinuxOnboardingActionRequest) => {
    if (!bridge) return;
    setBusy(true);
    setError(null);
    try {
      commit(await bridge.onboardingAction(request));
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : String(actionError));
    } finally {
      setBusy(false);
    }
  };

  const reset = async () => {
    if (!bridge) return;
    setBusy(true);
    setError(null);
    try {
      commit(await bridge.onboardingReset());
    } catch (resetError) {
      setError(resetError instanceof Error ? resetError.message : String(resetError));
    } finally {
      setBusy(false);
    }
  };

  const storeProviderCredential = async (providerID: string, label: string, apiKey: string) => {
    if (fixtureMode) {
      setProviderStatus('Credential storage is unavailable in fixture mode. Start the packaged shell to use native Secret Service.');
      return;
    }
    if (!bridge?.providerCredentialSlotUpsert) {
      setProviderStatus('Native provider credential storage is unavailable in this shell. Open Settings → Providers.');
      return;
    }
    setBusy(true);
    setProviderStatus(null);
    try {
      const next: ConfigSnapshot = await bridge.providerCredentialSlotUpsert({
        providerID,
        label,
        apiKey,
        isEnabled: true
      });
      const stored = next.providers?.find((provider) => provider.providerID === providerID)?.credentialSlots.length ?? 0;
      setProviderStatus(stored > 0 ? 'Credential stored by the daemon. Verify and continue to complete setup.' : 'Daemon accepted the credential; verify its provider status in Settings.');
    } catch (storeError) {
      setProviderStatus(storeError instanceof Error ? storeError.message : 'Credential storage failed.');
    } finally {
      setBusy(false);
    }
  };

  if (!bridgeReady || (bridge && !authorityReady && !error)) {
    return (
      <div className="onboarding-stage">
        <section className="onboarding-wizard" role="status" aria-label="Checking setup authority">
          <p className="onboarding-wizard-kicker">First-run setup</p>
          <h3>Checking daemon-owned setup</h3>
          <p className="onboarding-step-body">Reading verified Linux prerequisites from the local daemon.</p>
        </section>
      </div>
    );
  }

  if (!bridge || !authorityReady) {
    return (
      <div className="onboarding-stage">
        <section className="onboarding-wizard" role="alert" aria-labelledby="onboarding-unavailable-title">
          <p className="onboarding-wizard-kicker">First-run setup</p>
          <h3 id="onboarding-unavailable-title">Daemon setup authority is unavailable</h3>
          <p className="onboarding-step-body">
            Required setup cannot be completed from browser or fixture state. Start the packaged Linux app and its local daemon, then retry.
          </p>
          {error ? <Banner tone="degraded">{error}</Banner> : null}
          {bridge ? (
            <button type="button" className="onboarding-btn-primary" disabled={busy} onClick={() => setAuthorityAttempt((value) => value + 1)}>
              Retry daemon authority
            </button>
          ) : null}
        </section>
      </div>
    );
  }

  if (snapshot.completed) {
    return (
      <div className="onboarding-stage">
        <div className="onboarding-wizard setup-complete" role="status">
          <div className="setup-complete-mark" aria-hidden="true">✓</div>
          <h3>Setup verified</h3>
          <p>Every required prerequisite was verified by the daemon. Optional Linux integrations were acknowledged or deferred explicitly.</p>
          {error ? <Banner tone="degraded">{error}</Banner> : null}
          <div className="actions onboarding-actions">
            <div className="onboarding-actions-secondary">
              <button type="button" className="onboarding-btn-ghost" disabled={busy} onClick={() => void reset()}>
                Run setup again
              </button>
            </div>
            <button type="button" className="onboarding-btn-primary" onClick={() => setRoute('overview')}>
              <span>Open dashboard</span>
            </button>
          </div>
        </div>
      </div>
    );
  }

  const stepIndex = Math.max(0, ONBOARDING_STEPS.findIndex((step) => step.id === snapshot.currentStepID));
  const step = ONBOARDING_STEPS[stepIndex] ?? ONBOARDING_STEPS[0];
  const stepSnapshot = snapshot.steps.find((candidate) => candidate.id === step.id) ?? snapshot.steps[0];
  const canGoBack = stepIndex > 0;
  const progressFraction = (stepIndex + 1) / ONBOARDING_STEPS.length;
  const isPrivacy = step.id === 'privacy';
  const primaryLabel = isPrivacy
    ? 'Save choices'
    : step.requirement === 'required'
      ? stepSnapshot.state === 'blocked' ? 'Retry verification' : 'Verify and continue'
      : 'Acknowledge and continue';

  const advance = () => {
    if (isPrivacy) {
      void perform({
        stepID: step.id,
        action: 'save_privacy_choices',
        telemetryEnabled: privacyChoices.telemetryEnabled,
        cloudSyncEnabled: privacyChoices.cloudSyncEnabled
      });
      return;
    }
    void perform({
      stepID: step.id,
      action: step.requirement === 'required' ? 'verify' : 'acknowledge'
    });
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
          <div className="onboarding-progress-fill" style={{ width: `${Math.round(progressFraction * 100)}%` }} />
        </div>

        <div className="step-rail" aria-hidden="true">
          {ONBOARDING_STEPS.map((candidate, index) => {
            const state = snapshot.steps.find((value) => value.id === candidate.id)?.state ?? 'pending';
            return (
              <span
                key={candidate.id}
                className={`step-dot${index === stepIndex ? ' active' : ''}${isTerminal(state) ? ' done' : ''}${state === 'skipped' ? ' skipped' : ''}`}
              />
            );
          })}
        </div>

        <div className="onboarding-step" key={step.id}>
          <div className="onboarding-step-meta">
            <span className="onboarding-step-glyph" aria-hidden="true">{step.glyph}</span>
            <p className="onboarding-step-index">{step.kicker}</p>
          </div>
          <h3 id="onboarding-step-title">{step.title}</h3>
          <p className="onboarding-step-body">{step.body}</p>
          {isPrivacy ? (
            <fieldset className="onboarding-privacy-choices">
              <legend>Privacy choices</legend>
              <label>
                <input
                  type="checkbox"
                  checked={privacyChoices.telemetryEnabled}
                  onChange={(event) => setPrivacyChoices((value) => ({ ...value, telemetryEnabled: event.target.checked }))}
                />
                Share redacted reliability telemetry
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={privacyChoices.cloudSyncEnabled}
                  onChange={(event) => setPrivacyChoices((value) => ({ ...value, cloudSyncEnabled: event.target.checked }))}
                />
                Allow encrypted cloud sync after sign-in
              </label>
            </fieldset>
          ) : null}
          {step.id === 'provider_paths' && providerCatalog ? (
            <ProviderSetup
              catalog={providerCatalog}
              onStore={storeProviderCredential}
              disabled={busy}
              status={providerStatus}
            />
          ) : null}
        </div>

        {stepSnapshot.detail || error ? (
          <Banner
            tone={stepSnapshot.state === 'blocked' || error ? 'degraded' : 'ok'}
            role={stepSnapshot.state === 'blocked' || error ? 'alert' : 'status'}
          >
            <span className="retry-feedback">{error ?? stepSnapshot.detail}</span>
          </Banner>
        ) : null}

        <div className="actions onboarding-actions">
          <div className="onboarding-actions-secondary">
            {canGoBack ? (
              <button
                type="button"
                className="onboarding-btn-ghost"
                disabled={busy}
                onClick={() => void perform({ stepID: ONBOARDING_STEPS[stepIndex - 1].id, action: 'navigate' })}
              >
                Back
              </button>
            ) : null}
            {step.requirement === 'optional' ? (
              <button
                type="button"
                className="onboarding-btn-ghost"
                disabled={busy}
                onClick={() => void perform({ stepID: step.id, action: 'skip' })}
              >
                Skip for now
              </button>
            ) : null}
          </div>
          <button type="button" className="onboarding-btn-primary" disabled={busy} onClick={advance}>
            <span>{busy ? 'Checking…' : primaryLabel}</span>
          </button>
        </div>
      </section>
    </div>
  );
}
