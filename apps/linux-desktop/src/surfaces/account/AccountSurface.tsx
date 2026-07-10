import { useMemo, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { FailureStateList } from '../../components/FailureStateList.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { SurfaceCard } from '../../components/SurfaceCard.js';
import { useAccountStore } from '../../state/accountStore.js';
import type { AccountStatus } from '../../tauriBridge.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { accountPlanTier } from './accountPlanTier.js';
import { DeviceAuthPanel } from './DeviceAuthPanel.js';
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
    state: 'signed_out',
    signedIn: false,
    identityLabel: undefined,
    trustClass: 'linux-lower-trust',
    syncState: 'local-only',
    updatedAt: new Date(0).toISOString(),
    lastSyncAt: undefined
  };
}

export function AccountSurface() {
  const load = useAccountStore((s) => s.load);
  const data = useAccountStore((s) => s.data);
  const loading = useAccountStore((s) => s.loading);
  const error = useAccountStore((s) => s.error);
  const authPhase = useAccountStore((s) => s.authPhase);
  const authError = useAccountStore((s) => s.authError);
  const signOut = useAccountStore((s) => s.signOut);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const daemonStatus = useDaemonStatusCopy();
  const [confirmingSignOut, setConfirmingSignOut] = useState(false);

  useLaneLoad(load);

  const offline = !fixtureMode && !bridge && !loading && !data && Boolean(error);
  const statusForCard = data ?? (offline || error ? signedOutStatus() : null);
  const authBusy = authPhase === 'starting' || authPhase === 'pending' || authPhase === 'cancelling' || authPhase === 'signing-out';

  const politeSummary = useMemo(() => {
    if (authPhase === 'starting') return 'Starting secure browser sign-in.';
    if (authPhase === 'pending') return 'Browser sign-in is waiting for approval.';
    if (authPhase === 'cancelling') return 'Cancelling browser sign-in.';
    if (authPhase === 'expired') return 'The browser sign-in code expired.';
    if (authPhase === 'cancelled') return 'Browser sign-in cancelled.';
    if (authPhase === 'signing-out') return 'Signing out.';
    if (authPhase === 'error' && authError) return `Account action failed: ${authError}`;
    if (loading) return 'Loading account and sync status.';
    if (error) return `Account status unavailable: ${error}`;
    if (!data) return 'Account status not loaded.';
    if (!data.signedIn) return 'Signed out. Local-first mode is supported.';
    return `Signed in as ${data.identityLabel ?? 'Linux identity'}. Sync ${data.syncState}.`;
  }, [authError, authPhase, loading, error, data]);

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

      {authError && data?.signedIn && authPhase === 'error' ? (
        <Banner tone="degraded" role="alert">{authError}</Banner>
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
                <h3>Local-first is a supported mode</h3>
                <p className="muted">
                  You can work entirely on this machine. Sign-in happens in your browser through the daemon when you
                  choose; this shell never collects credentials.
                </p>
                {!offline ? <DeviceAuthPanel /> : null}
              </div>
            ) : (
              <p className="muted account-identity">
                Signed in as <strong>{statusForCard.identityLabel ?? 'Linux identity'}</strong>
              </p>
            )}
            <TrustBadge planTier={accountPlanTier(statusForCard)} />
            <SyncStateCard status={statusForCard} />
            {statusForCard.signedIn ? (
              <div className="account-signout">
                {confirmingSignOut ? (
                  <div className="account-signout-confirm" role="group" aria-label="Confirm sign out">
                    <p>Sign out of OpenBurnBar Cloud? Local SQLite data stays on this machine.</p>
                    <div className="actions">
                      <button
                        type="button"
                        className="danger"
                        disabled={authPhase === 'signing-out'}
                        onClick={() => void signOut().finally(() => setConfirmingSignOut(false))}
                      >
                        {authPhase === 'signing-out' ? 'Signing out…' : 'Confirm sign out'}
                      </button>
                      <button type="button" className="ghost" disabled={authPhase === 'signing-out'} onClick={() => setConfirmingSignOut(false)}>
                        Cancel
                      </button>
                    </div>
                  </div>
                ) : (
                  <button type="button" className="ghost" onClick={() => setConfirmingSignOut(true)}>Sign out</button>
                )}
              </div>
            ) : null}
          </div>
        </SurfaceCard>
      ) : null}

      <MembershipSection />

      <div className="actions">
        <button type="button" className="primary" disabled={loading || authBusy} onClick={() => void load()}>
          {loading ? 'Checking…' : 'Check again'}
        </button>
      </div>

      <FailureStateList cases={ACCOUNT_CASES} />
    </div>
  );
}
