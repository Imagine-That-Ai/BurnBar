import { useCallback, useEffect, useRef, useState } from 'react';
import { Banner } from '../components/Banner.js';
import { ONBOARDING_STEPS } from '../onboardingSteps.js';
import {
  cacheOnboarding,
  decodeLinuxOnboardingSnapshot,
  readOnboarding,
  type LinuxOnboardingActionRequest,
  type LinuxOnboardingPrivacyChoices,
  type LinuxOnboardingRepairAction,
  type LinuxOnboardingSnapshot
} from '../onboardingStore.js';
import type {
  AccountSignInOperation,
  AccountStatus,
  ConfigSnapshot,
  LinuxShellBridge,
  ProviderCatalog
} from '../tauriBridge.js';
import { useShellStore } from '../state/shellStore.js';
import './onboarding.css';

const OPENBURNBAR_LOGO = '/provider-logos/openburnbar.png';

const REPAIR_COPY: Record<LinuxOnboardingRepairAction, string> = {
  start_daemon: 'Start the packaged daemon, then retry the authenticated socket check.',
  unlock_secret_store: 'Unlock Secret Service or KWallet, then retry the ephemeral readback.',
  repair_provider_data: 'Check the XDG data directory and provider catalog, then retry first-data verification.',
  sign_in: 'Open the native account flow and finish cloud sign-in before retrying.',
  grant_portal: 'Approve the requested desktop portal permission, then retry the capability check.',
  enable_tray: 'Run inside a desktop session with a supported tray host, then retry the shell check.',
  open_updates: 'Install or select a signed package channel, then retry update verification.',
  choose_privacy: 'Choose both privacy controls and save them through the daemon.',
  retry: 'Retry the daemon-owned check.'
};

function isTerminal(state: LinuxOnboardingSnapshot['steps'][number]['state']): boolean {
  return state === 'verified' || state === 'acknowledged' || state === 'skipped';
}

function providerRouteStatus(
  provider: ProviderCatalog[number] | undefined,
  credentialStored: boolean
): string {
  if (provider?.health === 'healthy' && provider.failover?.eligible === true) {
    return credentialStored
      ? 'Credential stored and provider route verified by the daemon.'
      : 'Provider route verified by the daemon.';
  }
  return credentialStored
    ? 'Credential stored, but the daemon has not verified a healthy provider route. Retry provider verification before relying on this provider.'
    : 'Provider route is not verified by the daemon. Fix provider authentication, then retry verification.';
}

type CloudAuthPhase = 'unavailable' | 'signed-out' | 'authorizing' | 'awaiting-device-approval' | 'active';

function cloudAuthPhase(status: AccountStatus | null): CloudAuthPhase {
  if (!status) return 'unavailable';
  if (status.state === 'unavailable') return 'unavailable';
  if (status.state === 'authorizing') return 'authorizing';
  if (status.state === 'awaiting-device-approval') return 'awaiting-device-approval';
  if (status.state === 'active' || status.signedIn) return 'active';
  return 'signed-out';
}

function cloudAuthStatusCopy(status: AccountStatus | null, operation: AccountSignInOperation | null): string {
  switch (cloudAuthPhase(status)) {
    case 'authorizing':
      return 'The native browser sign-in is in progress. Finish authorization, then check again.';
    case 'awaiting-device-approval':
      return 'This installation is waiting for approval on the trusted device. Approve it, then check again.';
    case 'active':
      return 'A cloud identity is connected. Verify it with the daemon before continuing.';
    case 'signed-out':
      return operation
        ? 'The native sign-in operation started. Finish authorization in the browser, then check again.'
        : 'No cloud identity is connected. You can continue in local-first mode or start sign-in.';
    case 'unavailable':
      return status?.detail
        ? `Cloud sign-in is unavailable: ${status.detail}. Setup remains local-first until the packaged daemon is configured.`
        : 'Cloud sign-in is unavailable in this shell. Setup remains local-first until the packaged daemon is configured.';
  }
}

function cloudAuthErrorCopy(status: AccountStatus | null): string | null {
  const detail = status?.detail?.toLowerCase() ?? '';
  if (detail.includes('cancel')) return 'Cloud sign-in was cancelled. No cloud identity was connected.';
  if (
    detail.includes('denied')
    || detail.includes('reject')
    || detail.includes('authorization_failed')
    || detail.includes('authentication_failed')
  ) {
    return 'Cloud sign-in was denied or failed. Start sign-in again to retry.';
  }
  return null;
}

function cloudAuthPhaseForOperation(
  status: AccountStatus | null,
  operation: AccountSignInOperation | null
): CloudAuthPhase {
  const phase = cloudAuthPhase(status);
  if (phase !== 'signed-out' || !operation || cloudAuthErrorCopy(status)) return phase;
  const expiresAt = Date.parse(operation.expiresAt);
  return !Number.isFinite(expiresAt) || expiresAt > Date.now() ? 'authorizing' : phase;
}

function CloudIdentitySetup({
  bridge,
  fixtureMode,
  disabled,
  onVerify,
  onOpenAccount
}: {
  bridge: LinuxShellBridge | null;
  fixtureMode: boolean;
  disabled: boolean;
  onVerify: () => Promise<void>;
  onOpenAccount: () => void;
}) {
  const [status, setStatus] = useState<AccountStatus | null>(null);
  const [operation, setOperation] = useState<AccountSignInOperation | null>(null);
  const [loading, setLoading] = useState(true);
  const [busyAction, setBusyAction] = useState<'start' | 'cancel' | 'refresh' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const requestID = useRef(0);

  const loadStatus = useCallback(async () => {
    const currentRequest = ++requestID.current;
    setLoading(true);
    setError(null);
    if (fixtureMode) {
      if (currentRequest === requestID.current) {
        setStatus(null);
        setOperation(null);
        setLoading(false);
        setError('Cloud sign-in is unavailable in fixture mode. Start the packaged shell to use native account authentication.');
      }
      return;
    }
    if (!bridge || typeof bridge.accountStatus !== 'function') {
      if (currentRequest === requestID.current) {
        setStatus(null);
        setOperation(null);
        setLoading(false);
        setError('Native cloud sign-in is unavailable in this shell. Open the Account screen or start the packaged app.');
      }
      return;
    }
    try {
      const next = await bridge.accountStatus();
      if (currentRequest !== requestID.current) return;
      setStatus(next);
      if (cloudAuthPhase(next) === 'active' || cloudAuthErrorCopy(next)) setOperation(null);
    } catch (statusError) {
      if (currentRequest !== requestID.current) return;
      setError(statusError instanceof Error ? statusError.message : 'Cloud sign-in status could not be read.');
    } finally {
      if (currentRequest === requestID.current) setLoading(false);
    }
  }, [bridge, fixtureMode]);

  useEffect(() => {
    requestID.current += 1;
    void loadStatus();
    return () => {
      requestID.current += 1;
    };
  }, [loadStatus]);

  const phase = cloudAuthPhaseForOperation(status, operation);
  const operationID = status?.authorizationOperationID ?? operation?.operationID;
  const expiresAt = status?.authorizationExpiresAt ?? operation?.expiresAt;

  useEffect(() => {
    if (phase !== 'authorizing' && phase !== 'awaiting-device-approval') return undefined;
    const intervalID = window.setInterval(() => {
      void loadStatus();
    }, 2000);
    const expiration = expiresAt ? Date.parse(expiresAt) : Number.NaN;
    const remaining = expiration - Date.now();
    // Browsers clamp timers to a signed 32-bit duration. Long-lived daemon
    // operations remain covered by polling; only schedule the local expiry
    // hint when it can be represented by the host timer.
    const timeoutID = Number.isFinite(remaining) && remaining > 0 && remaining <= 2_147_483_647
      ? window.setTimeout(() => {
          setOperation(null);
          setStatus((current) => current
            ? {
                ...current,
                state: 'signed-out',
                signedIn: false,
                authorizationOperationID: undefined,
                authorizationExpiresAt: undefined
              }
            : current);
          setNotice('The cloud sign-in request expired. Start sign-in again.');
          void loadStatus();
        }, remaining)
      : undefined;
    return () => {
      window.clearInterval(intervalID);
      if (timeoutID !== undefined) window.clearTimeout(timeoutID);
    };
  }, [expiresAt, loadStatus, phase]);

  const beginSignIn = async () => {
    if (fixtureMode || !bridge || typeof bridge.accountBeginSignIn !== 'function') {
      setError(fixtureMode
        ? 'Cloud sign-in is unavailable in fixture mode. Start the packaged shell to use native account authentication.'
        : 'Native cloud sign-in is unavailable in this shell. Open the Account screen or start the packaged app.');
      return;
    }
    setBusyAction('start');
    setError(null);
    setNotice(null);
    try {
      const nextOperation = await bridge.accountBeginSignIn();
      setOperation(nextOperation);
      setStatus({
        state: 'authorizing',
        signedIn: false,
        trustClass: 'linux-lower-trust',
        syncState: 'local-only',
        authorizationOperationID: nextOperation.operationID,
        authorizationExpiresAt: nextOperation.expiresAt,
        deviceApprovalRequired: false
      });
      setNotice('Browser authorization started. Return here after completing sign-in.');
    } catch (signInError) {
      setError(signInError instanceof Error ? signInError.message : 'Cloud sign-in could not be started.');
    } finally {
      setBusyAction(null);
    }
  };

  const cancelSignIn = async () => {
    if (!bridge || typeof bridge.accountCancelSignIn !== 'function' || !operationID) {
      setError('No active cloud sign-in operation is available to cancel.');
      return;
    }
    setBusyAction('cancel');
    setError(null);
    try {
      const next = await bridge.accountCancelSignIn(operationID);
      setOperation(null);
      setStatus(next);
      setNotice('Cloud sign-in cancelled. No cloud identity was connected.');
    } catch (cancelError) {
      setError(cancelError instanceof Error ? cancelError.message : 'Cloud sign-in could not be cancelled.');
    } finally {
      setBusyAction(null);
    }
  };

  const refreshStatus = async () => {
    setBusyAction('refresh');
    setNotice(null);
    await loadStatus();
    setBusyAction(null);
  };

  const statusError = cloudAuthErrorCopy(status);
  const controlsDisabled = disabled || busyAction !== null;

  return (
    <section className="onboarding-cloud-setup" aria-labelledby="onboarding-cloud-title">
      <h4 id="onboarding-cloud-title">Cloud sign-in</h4>
      <p className="onboarding-cloud-status" role={error || statusError ? 'alert' : 'status'}>
        {loading && !status ? 'Reading daemon cloud identity state…' : error ?? statusError ?? cloudAuthStatusCopy(status, operation)}
      </p>
      {notice ? <p className="onboarding-cloud-status" role="status">{notice}</p> : null}
      {phase === 'active' ? (
        <button type="button" className="onboarding-btn-ghost" disabled={controlsDisabled} onClick={() => void onVerify()}>
          Verify cloud identity
        </button>
      ) : null}
      {phase === 'signed-out' ? (
        <button type="button" className="onboarding-btn-ghost" disabled={controlsDisabled} onClick={() => void beginSignIn()}>
          Start cloud sign-in
        </button>
      ) : null}
      {phase === 'authorizing' || phase === 'awaiting-device-approval' ? (
        <div className="onboarding-cloud-actions">
          <button type="button" className="onboarding-btn-ghost" disabled={controlsDisabled} onClick={() => void refreshStatus()}>
            {phase === 'awaiting-device-approval' ? 'Check approval' : 'Check sign-in'}
          </button>
          {operationID ? (
            <button type="button" className="onboarding-btn-ghost" disabled={controlsDisabled} onClick={() => void cancelSignIn()}>
              Cancel sign-in
            </button>
          ) : null}
        </div>
      ) : null}
      {phase === 'unavailable' ? (
        <div className="onboarding-cloud-actions">
          {!fixtureMode ? (
            <button type="button" className="onboarding-btn-ghost" disabled={controlsDisabled} onClick={() => void refreshStatus()}>
              Retry cloud sign-in
            </button>
          ) : null}
          <button type="button" className="onboarding-btn-ghost" disabled={controlsDisabled} onClick={onOpenAccount}>
            Open Account settings
          </button>
        </div>
      ) : null}
    </section>
  );
}

type ProviderCatalogLoadResult = {
  requestID: number;
  catalog: ProviderCatalog | null;
  stale: boolean;
};

function ProviderSetup({
  catalog,
  onStore,
  onVerify,
  onRetry,
  onOpenSettings,
  disabled,
  status,
  loading,
  error
}: {
  catalog: ProviderCatalog;
  onStore: (providerID: string, label: string, apiKey: string) => Promise<void>;
  onVerify: (providerID: string) => Promise<void>;
  onRetry: () => void;
  onOpenSettings: () => void;
  disabled: boolean;
  status: string | null;
  loading: boolean;
  error: string | null;
}) {
  const [providerID, setProviderID] = useState(catalog[0]?.id ?? '');
  const [label, setLabel] = useState('Primary');
  const [apiKey, setApiKey] = useState('');
  const selected = catalog.find((entry) => entry.id === providerID) ?? catalog[0];
  const selectedHealth = selected?.health ?? 'unknown';
  const selectedFailover = selected?.failover;

  useEffect(() => {
    // Keep the last selected ID during a failed refresh so the user can retry
    // that exact daemon route without leaving onboarding.
    if (catalog.length > 0 && !catalog.some((entry) => entry.id === providerID)) setProviderID(catalog[0]?.id ?? '');
  }, [catalog, providerID]);

  if (catalog.length === 0) {
    return (
      <section className="onboarding-provider-setup" aria-labelledby="onboarding-provider-title">
        <h4 id="onboarding-provider-title">Provider connection</h4>
        {loading ? (
          <>
            <p className="onboarding-provider-status muted" role="status">Reading the daemon provider catalog…</p>
            <div className="onboarding-provider-actions">
              <button type="button" className="onboarding-btn-ghost" disabled={disabled} onClick={onRetry}>
                Retry provider catalog
              </button>
              <button type="button" className="onboarding-btn-ghost" disabled={disabled} onClick={onOpenSettings}>
                Open provider settings
              </button>
            </div>
          </>
        ) : error ? (
          <>
            <p className="onboarding-provider-status" role="alert">{error}</p>
            <div className="onboarding-provider-actions">
              <button type="button" className="onboarding-btn-ghost" disabled={disabled} onClick={onRetry}>
                Retry provider catalog
              </button>
              <button
                type="button"
                className="onboarding-btn-ghost"
                disabled={disabled || !providerID}
                onClick={() => {
                  if (providerID) void onVerify(providerID);
                }}
              >
                Verify provider route
              </button>
              <button type="button" className="onboarding-btn-ghost" disabled={disabled} onClick={onOpenSettings}>
                Open provider settings
              </button>
            </div>
          </>
        ) : (
          <>
            <p className="muted">The daemon returned no provider catalog. Connect a provider from native settings, then retry this check.</p>
            <div className="onboarding-provider-actions">
              <button type="button" className="onboarding-btn-ghost" disabled={disabled} onClick={onRetry}>
                Retry provider catalog
              </button>
              <button
                type="button"
                className="onboarding-btn-ghost"
                disabled={disabled || !providerID}
                onClick={() => {
                  if (providerID) void onVerify(providerID);
                }}
              >
                Verify provider route
              </button>
              <button type="button" className="onboarding-btn-ghost" disabled={disabled} onClick={onOpenSettings}>
                Open provider settings
              </button>
            </div>
          </>
        )}
        {status ? <p className="onboarding-provider-status" role="status">{status}</p> : null}
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
        {selected?.provenance ? ` · ${selected.provenance}` : ''}
      </p>
      <p className="onboarding-provider-status muted" role="status">
        {selectedFailover?.detail ?? (selectedHealth === 'healthy'
          ? 'The daemon verified a provider route.'
          : 'The daemon has not verified a provider route yet; store a credential, then retry verification.')}
      </p>
      {loading ? <p className="onboarding-provider-status muted" role="status">Refreshing daemon-verified provider state…</p> : null}
      {error ? <p className="onboarding-provider-status" role="alert">{error}</p> : null}
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
      <button
        type="button"
        className="onboarding-btn-ghost"
        disabled={disabled || !selected}
        onClick={() => {
          if (selected) void onVerify(selected.id);
        }}
      >
        Verify provider route
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
  const [providerCatalogLoading, setProviderCatalogLoading] = useState(false);
  const [providerCatalogError, setProviderCatalogError] = useState<string | null>(null);
  const [providerStatus, setProviderStatus] = useState<string | null>(null);
  const providerCatalogRequestID = useRef(0);
  const [privacyChoices, setPrivacyChoices] = useState<LinuxOnboardingPrivacyChoices>(() =>
    snapshot.privacyChoices ?? { telemetryEnabled: false, cloudSyncEnabled: false }
  );
  const bridge = useShellStore((state) => state.bridge);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const setRoute = useShellStore((state) => state.setRoute);

  /**
   * Provider catalog responses are daemon evidence, not UI decoration. A
   * route change, retry, or credential mutation can make an earlier request
   * obsolete; only the newest response may update the catalog or status.
   */
  const loadProviderCatalog = useCallback(async (): Promise<ProviderCatalogLoadResult> => {
    const requestID = ++providerCatalogRequestID.current;
    setProviderCatalogLoading(true);
    setProviderCatalogError(null);
    if (!bridge) {
      if (requestID === providerCatalogRequestID.current) {
        setProviderCatalogLoading(false);
        setProviderCatalogError('The packaged daemon is unavailable. Start it, then retry the provider catalog check.');
        setProviderCatalog((current) => current ?? []);
      }
      return { requestID, catalog: null, stale: requestID !== providerCatalogRequestID.current };
    }
    try {
      const catalog = await bridge.providerCatalog();
      const stale = requestID !== providerCatalogRequestID.current;
      if (!stale) {
        setProviderCatalog(catalog);
        setProviderCatalogLoading(false);
        if (catalog.length === 0) {
          setProviderCatalogError('The daemon returned no providers. Connect one in provider settings, then retry this check.');
        }
      }
      return { requestID, catalog: stale ? null : catalog, stale };
    } catch {
      const stale = requestID !== providerCatalogRequestID.current;
      if (!stale) {
        setProviderCatalog((current) => current ?? []);
        setProviderCatalogLoading(false);
        setProviderCatalogError('The daemon provider catalog could not be read. Repair provider authentication or open provider settings, then retry.');
      }
      return { requestID, catalog: null, stale };
    }
  }, [bridge]);

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
        // Keep the renderer fail-closed even when a non-Tauri bridge (or a
        // future protocol version) bypasses the typed bridge decoder. Cache
        // validation alone is advisory and intentionally swallows failures.
        const authoritative = decodeLinuxOnboardingSnapshot(next);
        cacheOnboarding(authoritative);
        setSnapshot(authoritative);
        setPrivacyChoices(authoritative.privacyChoices ?? { telemetryEnabled: false, cloudSyncEnabled: false });
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
    if (!bridge || snapshot.currentStepID !== 'provider_paths') {
      providerCatalogRequestID.current += 1;
      setProviderCatalog(null);
      setProviderCatalogLoading(false);
      setProviderCatalogError(null);
      setProviderStatus(null);
      return () => {
        providerCatalogRequestID.current += 1;
      };
    }
    void loadProviderCatalog();
    return () => {
      providerCatalogRequestID.current += 1;
    };
  }, [bridge, loadProviderCatalog, snapshot.currentStepID]);

  const commit = (next: LinuxOnboardingSnapshot) => {
    // Decode action responses before mutating local state. This prevents a
    // malformed response from replacing the last known-good snapshot after a
    // cache write is rejected.
    const authoritative = decodeLinuxOnboardingSnapshot(next);
    cacheOnboarding(authoritative);
    setSnapshot(authoritative);
    if (authoritative.privacyChoices) setPrivacyChoices(authoritative.privacyChoices);
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
      if (stored === 0) {
        setProviderStatus('The daemon accepted the request but did not report a credential slot. Provider route remains unverified.');
        return;
      }
      const refreshed = await loadProviderCatalog();
      if (refreshed.stale) return;
      if (refreshed.catalog) {
        setProviderStatus(providerRouteStatus(
          refreshed.catalog.find((provider) => provider.id === providerID),
          true
        ));
      } else {
        setProviderStatus('Credential stored, but provider route verification is unavailable. No route is marked ready; retry provider verification.');
      }
    } catch (storeError) {
      setProviderStatus(storeError instanceof Error ? storeError.message : 'Credential storage failed.');
    } finally {
      setBusy(false);
    }
  };

  const verifyProviderRoute = async (providerID: string) => {
    if (fixtureMode) {
      setProviderStatus('Provider route verification is unavailable in fixture mode. Start the packaged shell to use the daemon.');
      return;
    }
    if (!bridge) {
      setProviderStatus('Provider route verification requires the packaged daemon.');
      return;
    }
    setBusy(true);
    setProviderStatus('Checking provider route with the daemon…');
    try {
      const refreshed = await loadProviderCatalog();
      if (refreshed.stale) return;
      if (refreshed.catalog) {
        setProviderStatus(providerRouteStatus(
          refreshed.catalog.find((provider) => provider.id === providerID),
          false
        ));
      } else {
        setProviderStatus('Provider route verification is unavailable. No provider route is marked ready; retry after repairing provider authentication.');
      }
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
      <section className="onboarding-wizard" aria-labelledby="onboarding-step-title" aria-busy={busy}>
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
          {step.id === 'provider_paths' ? (
            <ProviderSetup
              catalog={providerCatalog ?? []}
              onStore={storeProviderCredential}
              onVerify={verifyProviderRoute}
              onRetry={() => void loadProviderCatalog()}
              onOpenSettings={() => setRoute('settings')}
              disabled={busy}
              status={providerStatus}
              loading={providerCatalogLoading}
              error={providerCatalogError}
            />
          ) : null}
          {step.id === 'cloud_identity' ? (
            <CloudIdentitySetup
              bridge={bridge}
              fixtureMode={fixtureMode}
              disabled={busy}
              onVerify={() => perform({ stepID: 'cloud_identity', action: 'verify' })}
              onOpenAccount={() => setRoute('account')}
            />
          ) : null}
        </div>

        {stepSnapshot.detail || error ? (
          <Banner
            tone={stepSnapshot.state === 'blocked' || error ? 'degraded' : 'ok'}
            role={stepSnapshot.state === 'blocked' || error ? 'alert' : 'status'}
          >
            <span className="retry-feedback">
              {error ?? stepSnapshot.detail}
              {!error && stepSnapshot.repairAction ? REPAIR_COPY[stepSnapshot.repairAction] : ''}
            </span>
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
              <>
                <button
                  type="button"
                  className="onboarding-btn-ghost"
                  disabled={busy}
                  onClick={() => void perform({ stepID: step.id, action: 'verify' })}
                >
                  {stepSnapshot.state === 'blocked' ? 'Retry check' : 'Check integration'}
                </button>
                <button
                  type="button"
                  className="onboarding-btn-ghost"
                  disabled={busy}
                  onClick={() => void perform({ stepID: step.id, action: 'skip' })}
                >
                  Skip for now
                </button>
              </>
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
