import { useEffect, useMemo, useRef, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { FailureStateList } from '../../components/FailureStateList.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { SurfaceCard } from '../../components/SurfaceCard.js';
import { useAccountStore } from '../../state/accountStore.js';
import type { AccountStatus } from '../../tauriBridge.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { accountPlanTier } from './accountPlanTier.js';
import { MembershipSection } from './membership/MembershipSection.js';
import { SyncStateCard } from './SyncStateCard.js';
import { TrustBadge } from './TrustBadge.js';
import { CopyPathButton } from '../system/CopyPathButton.js';
import './account.css';
import '../system/system.css';

const ACCOUNT_CASES = [
  {
    id: 'login-required',
    title: 'Signed out',
    recovery: 'Use lower-trust Linux identity for cloud sync; local SQLite remains canonical while signed out.'
  },
  {
    id: 'sync-paused',
    title: 'Sync paused',
    recovery: 'Encrypted private rows stay local until you opt back in.'
  },
  {
    id: 'quota-exhausted',
    title: 'Quota exhausted',
    recovery: 'Switch providers, lower model tier, or wait for the reset window.'
  }
];

const RETRYABLE_AUTH_FAILURES = new Set([
  'authorization_failed',
  'cloud_response_invalid',
  'cloud_unavailable',
  'reauthorization_required',
  'session_changed'
]);

function signedOutStatus(): AccountStatus {
  return {
    state: 'signed-out',
    signedIn: false,
    identityLabel: undefined,
    trustClass: 'linux-lower-trust',
    syncState: 'local-only',
    lastSyncAt: undefined,
    deviceApprovalRequired: false
  };
}

function authorizationExpiryTimestamp(status: AccountStatus | null): number | null {
  if (status?.state !== 'authorizing' || !status.authorizationExpiresAt) return null;
  const timestamp = Date.parse(status.authorizationExpiresAt);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function unavailableCopy(detail?: string): string {
  switch (detail) {
    case 'missing_cloud_configuration':
      return 'This Linux build is missing its cloud sign-in configuration. Install an official configured build or contact support.';
    case 'secure_store_unavailable':
      return 'Unlock or repair your desktop keyring, then check again.';
    case 'installation_identity_unavailable':
      return 'OpenBurnBar could not load this installation identity. Check keyring access, restart the app, then check again.';
    case 'cloud_unavailable':
      return 'Cloud sign-in could not be reached. Check your network connection, then check again.';
    case 'cloud_response_invalid':
      return 'Cloud sign-in returned an invalid response. Check again later or contact support.';
    case 'device_rejected':
      return 'This installation key was rejected or revoked. Replace it to request approval with a new fingerprint.';
    case 'app_check_configuration_rejected':
      return 'This build uses a Linux App Check application that is not allowlisted. Install an official configured build or contact support.';
    case 'reauthorization_required':
      return 'The cloud session expired. Sign in again to continue.';
    case 'session_changed':
      return 'The account session changed while the request was running. Check again before retrying sign-in.';
    case 'authorization_failed':
      return 'The browser authorization could not be completed. Check again before retrying sign-in.';
    default:
      return 'Cloud sign-in is temporarily unavailable. Check the daemon and keyring status, then check again.';
  }
}

type DeviceTrustPosture = {
  state: 'signed-out' | 'authorizing' | 'pending' | 'active' | 'rejected' | 'unavailable';
  title: string;
  detail: string;
};

function deviceTrustPosture(status: AccountStatus): DeviceTrustPosture {
  if (status.detail === 'device_rejected') {
    return {
      state: 'rejected',
      title: 'Installation rejected',
      detail: 'This installation key was rejected by cloud device policy. Replace the key to request approval again.'
    };
  }
  if (status.state === 'unavailable') {
    return {
      state: 'unavailable',
      title: 'Device authorization unavailable',
      detail: 'The daemon has not provided a current device-authorization result. Check again after restoring account access.'
    };
  }
  if (status.state === 'awaiting-device-approval' || status.deviceApprovalRequired) {
    return {
      state: 'pending',
      title: 'Approval pending on a trusted device',
      detail: 'Check again refreshes daemon authority. Linux can request approval, but cannot approve or revoke trusted devices locally.'
    };
  }
  if (status.state === 'authorizing') {
    return {
      state: 'authorizing',
      title: 'Waiting for account authorization',
      detail: 'Finish the browser sign-in first. Device approval status will appear after the daemon receives the account result.'
    };
  }
  if (status.signedIn) {
    return {
      state: 'active',
      title: 'Account session active',
      detail: 'This shell has a current account session. Trusted-device approval and revocation remain native companion-device actions.'
    };
  }
  return {
    state: 'signed-out',
    title: 'No cloud device session',
    detail: 'Local-first work is available. Sign in through the browser to request account and trusted-device authorization.'
  };
}

export function AccountSurface() {
  const load = useAccountStore((s) => s.load);
  const data = useAccountStore((s) => s.data);
  const loading = useAccountStore((s) => s.loading);
  const busyAction = useAccountStore((s) => s.busyAction);
  const error = useAccountStore((s) => s.error);
  const beginSignIn = useAccountStore((s) => s.beginSignIn);
  const cancelSignIn = useAccountStore((s) => s.cancelSignIn);
  const rotateIdentity = useAccountStore((s) => s.rotateIdentity);
  const signOut = useAccountStore((s) => s.signOut);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const daemonStatus = useDaemonStatusCopy();
  const shellContextRef = useRef({ fixtureMode, bridge });
  const [confirmingSignOut, setConfirmingSignOut] = useState(false);
  const [confirmingIdentityRotation, setConfirmingIdentityRotation] = useState(false);
  const [clockNow, setClockNow] = useState(() => Date.now());

  const authorizationExpiresAt = authorizationExpiryTimestamp(data);
  const authorizationExpired = authorizationExpiresAt !== null && authorizationExpiresAt <= clockNow;

  useLaneLoad(load);

  useEffect(() => {
    const previous = shellContextRef.current;
    if (previous.fixtureMode === fixtureMode && previous.bridge === bridge) return;
    shellContextRef.current = { fixtureMode, bridge };
    // Never let a previous daemon identity survive a shell replacement. The
    // store fences late mutations; this refresh hydrates the new authority.
    useAccountStore.getState().invalidateForShellContext();
    void load();
  }, [bridge, fixtureMode, load]);

  useEffect(() => {
    if (authorizationExpiresAt === null || authorizationExpired) return;
    const delay = authorizationExpiresAt - Date.now();
    if (delay <= 0) return;
    const timer = window.setTimeout(() => setClockNow(Date.now()), delay);
    return () => window.clearTimeout(timer);
  }, [authorizationExpiresAt, authorizationExpired]);

  useEffect(() => {
    if (data?.state !== 'authorizing' && data?.state !== 'awaiting-device-approval') return;
    // Once the daemon-provided browser authorization deadline has passed, stop
    // polling a potentially abandoned operation. The user can cancel it or
    // use Check again to obtain a fresh daemon-authoritative snapshot.
    if (authorizationExpired) return;
    const timer = window.setInterval(() => void load(), 2_000);
    return () => window.clearInterval(timer);
  }, [authorizationExpired, data?.state, load]);

  const offline = !fixtureMode && !bridge && !loading && !data && Boolean(error);
  const statusForCard = data ?? (offline || error ? signedOutStatus() : null);
  const authUnavailable = statusForCard?.state === 'unavailable';
  const deviceRejected = statusForCard?.detail === 'device_rejected';
  const authRetryAvailable = authUnavailable && RETRYABLE_AUTH_FAILURES.has(statusForCard?.detail ?? '');
  // A daemon transitional/error snapshot may carry the previous account's
  // signedIn bit for diagnostics. Never render that identity or offer a
  // destructive sign-out action until an authoritative active snapshot lands.
  const displayStatus = statusForCard?.state === 'unavailable'
    ? {
        ...statusForCard,
        signedIn: false,
        identityLabel: undefined,
        syncState: 'local-only' as const,
        lastSyncAt: undefined
      }
    : statusForCard;
  const trustPosture = displayStatus ? deviceTrustPosture(displayStatus) : null;

  const politeSummary = useMemo(() => {
    if (loading) return 'Loading account and sync status.';
    if (error) return `Account status unavailable: ${error}`;
    if (!data) return 'Account status not loaded.';
    if (data.state === 'unavailable') return `Cloud sign-in unavailable. ${unavailableCopy(data.detail)}`;
    if (data.state === 'authorizing') {
      return authorizationExpired
        ? 'Browser sign-in authorization expired. Cancel it, then start sign-in again.'
        : 'Browser sign-in is in progress.';
    }
    if (data.state === 'awaiting-device-approval') return 'Linux device approval is pending on a trusted device.';
    if (!data.signedIn) return 'Signed out. Local-first mode is supported.';
    return `Signed in as ${data.identityLabel ?? 'Linux identity'}. Sync ${data.syncState}.`;
  }, [authorizationExpired, loading, error, data]);

  return (
    <div className="account-stack">
      <div className="account-status-announcer" role="status" aria-live="polite" aria-atomic="true">
        {politeSummary}
      </div>

      {loading ? (
        <Banner tone="ok" role="status">
          Loading account and sync posture…
        </Banner>
      ) : null}

      {error && !offline ? (
        <Banner tone="degraded" role="alert">
          {error}
        </Banner>
      ) : null}

      {data?.state === 'authorizing' ? (
        <Banner tone={authorizationExpired ? 'degraded' : 'ok'} role={authorizationExpired ? 'alert' : 'status'}>
          {authorizationExpired
            ? 'Browser sign-in expired. Cancel this request, then start sign-in again.'
            : 'Complete sign-in in the browser. This window will update automatically.'}
        </Banner>
      ) : null}

      {data?.state === 'awaiting-device-approval' || data?.deviceApprovalRequired ? (
        <Banner tone="degraded" role="status">
          Approve this Linux installation from Devices &amp; Sync on a trusted OpenBurnBar device.
        </Banner>
      ) : null}

      {data?.state === 'unavailable' ? (
        <Banner tone="degraded" role="alert">
          <strong>Cloud sign-in is unavailable.</strong> {unavailableCopy(data.detail)}
        </Banner>
      ) : null}

      {offline ? (
        <OfflineNotice
          status={daemonStatus}
          summary="Account and sync status need the packaged Linux shell."
          fixtureMode={fixtureMode}
        />
      ) : null}

      {!loading && displayStatus ? (
        <SurfaceCard title="Identity and sync" titleId="account-identity-panel">
          <div className="account-identity-card">
            {!displayStatus.signedIn ? (
              <div className="account-hero">
                <div className="account-hero-icon" aria-hidden="true">
                  <svg viewBox="0 0 64 64" focusable="false">
                    <circle cx="32" cy="32" r="30" fill="none" stroke="currentColor" strokeWidth="1.5" />
                    <circle cx="32" cy="26" r="10" fill="currentColor" opacity="0.35" />
                    <path
                      d="M14 52c4-12 12-18 18-18s14 6 18 18"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.5"
                      strokeLinecap="round"
                    />
                    <text x="44" y="22" fontSize="14" fill="currentColor" fontFamily="var(--font-mono)">
                      ?
                    </text>
                  </svg>
                </div>
                <h3>{authUnavailable ? 'Cloud sign-in is unavailable' : 'Local-first is a supported mode'}</h3>
                {authUnavailable ? (
                  <p className="muted">Local work remains available while you restore cloud sign-in.</p>
                ) : (
                  <p className="muted">
                    You can work entirely on this machine. Sign-in happens in your browser through the daemon when you
                    choose—this shell never collects credentials.
                  </p>
                )}
              </div>
            ) : (
              <p className="muted account-identity">
                Signed in as <strong>{displayStatus.identityLabel ?? 'Linux identity'}</strong>
              </p>
            )}
            {displayStatus.installationDeviceID && displayStatus.installationSafetyFingerprint ? (
              <section className="account-installation-verification" aria-labelledby="installation-verification-title">
                <h3 id="installation-verification-title">Installation verification</h3>
                <dl>
                  <div>
                    <dt>Device ID</dt>
                    <dd className="account-verification-value">
                      <code>{displayStatus.installationDeviceID}</code>
                      <CopyPathButton path={displayStatus.installationDeviceID} label="Copy device ID" />
                    </dd>
                  </div>
                  <div>
                    <dt>Safety fingerprint</dt>
                    <dd className="account-verification-value">
                      <code>{displayStatus.installationSafetyFingerprint}</code>
                      <CopyPathButton path={displayStatus.installationSafetyFingerprint} label="Copy fingerprint" />
                    </dd>
                  </div>
                </dl>
                <p className="account-installation-note muted">
                  Compare both values on the trusted iPad before approving this Linux installation. Linux cannot approve
                  or revoke trusted devices locally; those high-risk mutations require signed native-device authorization.
                </p>
              </section>
            ) : null}
            <TrustBadge planTier={accountPlanTier(displayStatus)} />
            {trustPosture ? (
              <section
                className={`account-device-trust-card account-device-trust-card--${trustPosture.state}`}
                data-device-trust-state={trustPosture.state}
                aria-labelledby="account-device-trust-title"
              >
                <div className="account-device-trust-heading">
                  <span className="account-device-trust-mark" aria-hidden="true" />
                  <div>
                    <h3 id="account-device-trust-title">Trusted-device posture</h3>
                    <p>{trustPosture.title}</p>
                  </div>
                </div>
                <p className="account-device-trust-detail muted">{trustPosture.detail}</p>
              </section>
            ) : null}
            <SyncStateCard status={displayStatus} />
          </div>
        </SurfaceCard>
      ) : null}

      <MembershipSection />

      <div className="actions">
        {!displayStatus?.signedIn && displayStatus?.state !== 'authorizing' && (!authUnavailable || authRetryAvailable) ? (
          <button
            type="button"
            className="primary"
            disabled={loading || busyAction !== null || fixtureMode || !bridge}
            onClick={() => void beginSignIn()}
          >
            {busyAction === 'sign-in' ? 'Opening browser…' : authRetryAvailable ? 'Retry sign-in' : 'Sign in'}
          </button>
        ) : null}
        {authUnavailable && !authRetryAvailable ? (
          <button type="button" className="primary" disabled>
            Sign in unavailable
          </button>
        ) : null}
        {displayStatus?.state === 'authorizing' ? (
          <button
            type="button"
            className="ghost"
            disabled={busyAction !== null}
            onClick={() => void cancelSignIn()}
          >
            {busyAction === 'cancel' ? 'Cancelling…' : authorizationExpired ? 'Cancel expired sign-in' : 'Cancel sign-in'}
          </button>
        ) : null}
        {deviceRejected && !confirmingIdentityRotation ? (
          <button
            type="button"
            className="danger"
            disabled={busyAction !== null || fixtureMode || !bridge}
            onClick={() => setConfirmingIdentityRotation(true)}
          >
            Replace installation key
          </button>
        ) : null}
        {deviceRejected && confirmingIdentityRotation ? (
          <div className="account-signout-confirmation" role="group" aria-label="Confirm installation key replacement">
            <span>A new device ID and safety fingerprint will require approval from your trusted iPad.</span>
            <button
              type="button"
              className="danger"
              disabled={busyAction !== null}
              onClick={() => {
                void rotateIdentity().finally(() => setConfirmingIdentityRotation(false));
              }}
            >
              {busyAction === 'rotate-identity' ? 'Replacing key…' : 'Confirm key replacement'}
            </button>
            <button
              type="button"
              className="ghost"
              disabled={busyAction !== null}
              onClick={() => setConfirmingIdentityRotation(false)}
            >
              Keep current key
            </button>
          </div>
        ) : null}
        {displayStatus?.signedIn && !confirmingSignOut ? (
          <button type="button" className="ghost" disabled={busyAction !== null} onClick={() => setConfirmingSignOut(true)}>
            Sign out
          </button>
        ) : null}
        {displayStatus?.signedIn && confirmingSignOut ? (
          <div className="account-signout-confirmation" role="group" aria-label="Confirm sign out">
            <span>Sign out and stop cloud-backed controller routes?</span>
            <button
              type="button"
              className="danger"
              disabled={busyAction !== null}
              onClick={() => {
                setConfirmingSignOut(false);
                void signOut();
              }}
            >
              {busyAction === 'sign-out' ? 'Signing out…' : 'Confirm sign out'}
            </button>
            <button type="button" className="ghost" disabled={busyAction !== null} onClick={() => setConfirmingSignOut(false)}>
              Keep signed in
            </button>
          </div>
        ) : null}
        <button type="button" className="ghost" disabled={loading || busyAction !== null} onClick={() => void load()}>
          {loading ? 'Checking…' : 'Check again'}
        </button>
      </div>

      <FailureStateList cases={ACCOUNT_CASES} />
    </div>
  );
}
