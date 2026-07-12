import { useEffect, useMemo, useState } from 'react';
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
import './account.css';

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
    case 'session_changed':
      return 'The account session changed while the request was running. Check again before retrying sign-in.';
    case 'authorization_failed':
      return 'The browser authorization could not be completed. Check again before retrying sign-in.';
    default:
      return 'Cloud sign-in is temporarily unavailable. Check the daemon and keyring status, then check again.';
  }
}

export function AccountSurface() {
  const load = useAccountStore((s) => s.load);
  const data = useAccountStore((s) => s.data);
  const loading = useAccountStore((s) => s.loading);
  const busyAction = useAccountStore((s) => s.busyAction);
  const error = useAccountStore((s) => s.error);
  const beginSignIn = useAccountStore((s) => s.beginSignIn);
  const cancelSignIn = useAccountStore((s) => s.cancelSignIn);
  const signOut = useAccountStore((s) => s.signOut);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const daemonStatus = useDaemonStatusCopy();
  const [confirmingSignOut, setConfirmingSignOut] = useState(false);

  useLaneLoad(load);

  useEffect(() => {
    if (data?.state !== 'authorizing' && data?.state !== 'awaiting-device-approval') return;
    const timer = window.setInterval(() => void load(), 2_000);
    return () => window.clearInterval(timer);
  }, [data?.state, load]);

  const offline = !fixtureMode && !bridge && !loading && !data && Boolean(error);
  const statusForCard = data ?? (offline || error ? signedOutStatus() : null);
  const authUnavailable = statusForCard?.state === 'unavailable';

  const politeSummary = useMemo(() => {
    if (loading) return 'Loading account and sync status.';
    if (error) return `Account status unavailable: ${error}`;
    if (!data) return 'Account status not loaded.';
    if (data.state === 'unavailable') return `Cloud sign-in unavailable. ${unavailableCopy(data.detail)}`;
    if (data.state === 'authorizing') return 'Browser sign-in is in progress.';
    if (data.state === 'awaiting-device-approval') return 'Linux device approval is pending on a trusted device.';
    if (!data.signedIn) return 'Signed out. Local-first mode is supported.';
    return `Signed in as ${data.identityLabel ?? 'Linux identity'}. Sync ${data.syncState}.`;
  }, [loading, error, data]);

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
        <Banner tone="ok" role="status">
          Complete sign-in in the browser. This window will update automatically.
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

      {!loading && statusForCard ? (
        <SurfaceCard title="Identity and sync" titleId="account-identity-panel">
          <div className="account-identity-card">
            {!statusForCard.signedIn ? (
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
                Signed in as <strong>{statusForCard.identityLabel ?? 'Linux identity'}</strong>
              </p>
            )}
            <TrustBadge planTier={accountPlanTier(statusForCard)} />
            <SyncStateCard status={statusForCard} />
          </div>
        </SurfaceCard>
      ) : null}

      <MembershipSection />

      <div className="actions">
        {!statusForCard?.signedIn && statusForCard?.state !== 'authorizing' && !authUnavailable ? (
          <button
            type="button"
            className="primary"
            disabled={loading || busyAction !== null || fixtureMode || !bridge}
            onClick={() => void beginSignIn()}
          >
            {busyAction === 'sign-in' ? 'Opening browser…' : 'Sign in'}
          </button>
        ) : null}
        {authUnavailable ? (
          <button type="button" className="primary" disabled>
            Sign in unavailable
          </button>
        ) : null}
        {statusForCard?.state === 'authorizing' ? (
          <button
            type="button"
            className="ghost"
            disabled={busyAction !== null}
            onClick={() => void cancelSignIn()}
          >
            {busyAction === 'cancel' ? 'Cancelling…' : 'Cancel sign-in'}
          </button>
        ) : null}
        {statusForCard?.signedIn && !confirmingSignOut ? (
          <button type="button" className="ghost" disabled={busyAction !== null} onClick={() => setConfirmingSignOut(true)}>
            Sign out
          </button>
        ) : null}
        {statusForCard?.signedIn && confirmingSignOut ? (
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
