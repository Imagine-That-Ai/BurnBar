import { useMemo } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { FailureStateList } from '../../components/FailureStateList.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { SurfaceCard } from '../../components/SurfaceCard.js';
import { useAccountStore } from '../../state/accountStore.js';
import type { AccountStatus } from '../../tauriBridge.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { accountPlanTier } from './accountPlanTier.js';
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
    signedIn: false,
    identityLabel: undefined,
    trustClass: 'linux-lower-trust',
    syncState: 'local-only',
    lastSyncAt: undefined
  };
}

export function AccountSurface() {
  const load = useAccountStore((s) => s.load);
  const data = useAccountStore((s) => s.data);
  const loading = useAccountStore((s) => s.loading);
  const error = useAccountStore((s) => s.error);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const daemonStatus = useDaemonStatusCopy();

  useLaneLoad(load);

  const offline = !fixtureMode && !bridge && !loading && !data && Boolean(error);
  const statusForCard = data ?? (offline || error ? signedOutStatus() : null);

  const politeSummary = useMemo(() => {
    if (loading) return 'Loading account and sync status.';
    if (error) return `Account status unavailable: ${error}`;
    if (!data) return 'Account status not loaded.';
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
                  choose—this shell never collects credentials.
                </p>
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

      <div className="actions">
        <button type="button" className="primary" disabled={loading} onClick={() => void load()}>
          {loading ? 'Checking…' : 'Check again'}
        </button>
      </div>

      <p className="muted account-signin-hint">
        To sign in, complete browser-mediated auth from your daemon workflow, then use Check again.
      </p>

      <FailureStateList cases={ACCOUNT_CASES} />
    </div>
  );
}