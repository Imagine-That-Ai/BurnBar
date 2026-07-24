// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountStatus, LinuxCloudSyncStatus } from '../../tauriBridge.js';
import { useAccountStore } from '../../state/accountStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { accountPlanTier } from './accountPlanTier.js';
import { AccountSurface } from './AccountSurface.js';

function resetStores(): void {
  useAccountStore.setState(useAccountStore.getInitialState());
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    health: null,
    healthError: null,
    healthBusy: false
  });
}

function setAccount(
  partial: Partial<{ data: AccountStatus | null; loading: boolean; error: string | null }>
): void {
  useAccountStore.setState({
    data: partial.data ?? null,
    loading: partial.loading ?? false,
    error: partial.error ?? null
  });
}

function deferred<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((continuation) => {
    resolve = continuation;
  });
  return { promise, resolve };
}

const signedOut: AccountStatus = {
  state: 'signed-out',
  signedIn: false,
  trustClass: 'linux-lower-trust',
  syncState: 'local-only',
  deviceApprovalRequired: false
};

const signedInActive: AccountStatus = {
  state: 'active',
  signedIn: true,
  identityLabel: 'user@example.com',
  trustClass: 'linux-lower-trust',
  syncState: 'active',
  lastSyncAt: new Date(Date.now() - 3_600_000).toISOString(),
  deviceApprovalRequired: false
};

const signedInPaused: AccountStatus = {
  state: 'active',
  signedIn: true,
  identityLabel: 'user@example.com',
  trustClass: 'linux-lower-trust',
  syncState: 'paused',
  deviceApprovalRequired: false
};

const awaitingApproval: AccountStatus = {
  state: 'awaiting-device-approval',
  signedIn: false,
  trustClass: 'linux-lower-trust',
  syncState: 'local-only',
  deviceApprovalRequired: true,
  installationDeviceID: `linux_${'ab'.repeat(32)}`,
  installationSafetyFingerprint: Array(16).fill('ABAB').join(' ')
};

const unavailable: AccountStatus = {
  ...signedOut,
  state: 'unavailable',
  detail: 'secure_store_unavailable'
};

const rejectedIdentity: AccountStatus = {
  ...signedOut,
  state: 'unavailable',
  detail: 'device_rejected'
};

describe('accountPlanTier', () => {
  it('maps signed-out to local', () => {
    expect(accountPlanTier(signedOut)).toBe('local');
  });

  it('maps signed-in sync to cloud', () => {
    expect(accountPlanTier(signedInActive)).toBe('cloud');
    expect(accountPlanTier(signedInPaused)).toBe('cloud');
  });
});

describe('AccountSurface', () => {
  beforeEach(() => {
    resetStores();
    vi.spyOn(useAccountStore.getState(), 'load').mockImplementation(async () => {});
  });
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('renders signed-out hero and local-first copy', () => {
    setAccount({ data: signedOut });
    const { container } = render(<AccountSurface />);
    expect(screen.getByText(/Local-first is a supported mode/i)).toBeTruthy();
    expect(screen.getByTestId('canonical-invariant').textContent).toBe('Local SQLite remains canonical');
    expect(container.querySelector('input[type="password"]')).toBeNull();
    expect(container.querySelector('.account-hero-icon')).not.toBeNull();
    expect(screen.getByText(/Plan · Local/i)).toBeTruthy();
    expect(screen.getByRole('heading', { name: /Trusted-device posture/i })).toBeTruthy();
    expect(screen.getByText(/No cloud device session/i)).toBeTruthy();
    expect(container.querySelector('#account-identity-panel')).not.toBeNull();
  });

  it('renders signed-in active sync with last sync', () => {
    setAccount({ data: signedInActive });
    render(<AccountSurface />);
    expect(screen.getByText('user@example.com', { selector: 'strong' })).toBeTruthy();
    expect(screen.getByRole('heading', { name: /Encrypted sync active/i })).toBeTruthy();
    expect(screen.getByText(/Last sync/i)).toBeTruthy();
    expect(screen.getByTestId('canonical-invariant')).toBeTruthy();
    expect(screen.getByText(/Plan · Cloud/i)).toBeTruthy();
    expect(screen.getByText(/Account session active/i)).toBeTruthy();
    expect(screen.getByText(/approval and revocation remain native companion-device actions/i)).toBeTruthy();
  });

  it('hydrates daemon sync posture and offers a bounded sync action', async () => {
    const status: LinuxCloudSyncStatus = {
      phase: 'ready',
      pendingMutationCount: 2,
      consecutiveFailures: 0,
      enabledDomains: ['text_expansion'],
      remoteAccessEnabled: false,
      vaultKeyAvailable: true
    };
    const linuxCloudSyncStatus = vi.fn(async () => status);
    const linuxCloudSyncRun = vi.fn(async () => ({
      pushedCount: 2,
      appliedRemoteCount: 1,
      retainedLocalConflictCount: 0,
      status: { ...status, pendingMutationCount: 0 }
    }));
    useShellStore.setState({
      bridge: { linuxCloudSyncStatus, linuxCloudSyncRun } as never
    });
    setAccount({ data: signedInActive });

    render(<AccountSurface />);

    await waitFor(() => expect(screen.getByTestId('cloud-sync-posture')).toBeTruthy());
    expect(screen.getByTestId('cloud-sync-posture').textContent).toMatch(/2 pending changes/i);
    fireEvent.click(screen.getByRole('button', { name: 'Sync now' }));
    await waitFor(() => expect(linuxCloudSyncRun).toHaveBeenCalledWith(false));
    await waitFor(() => expect(screen.getByTestId('cloud-sync-posture').textContent).toMatch(/no pending changes/i));
  });

  it('does not call an optimistic account snapshot active when the keyring is locked', async () => {
    const linuxCloudSyncStatus = vi.fn(async (): Promise<LinuxCloudSyncStatus> => ({
      phase: 'locked',
      pendingMutationCount: 1,
      consecutiveFailures: 0,
      enabledDomains: ['text_expansion'],
      remoteAccessEnabled: false,
      vaultKeyAvailable: false
    }));
    useShellStore.setState({ bridge: { linuxCloudSyncStatus } as never });
    setAccount({ data: signedInActive });

    render(<AccountSurface />);

    await waitFor(() => expect(screen.getByRole('heading', { name: 'Sync keyring locked' })).toBeTruthy());
    expect((screen.getByRole('button', { name: 'Sync now' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('renders signed-in paused sync', () => {
    setAccount({ data: signedInPaused });
    render(<AccountSurface />);
    expect(screen.getByRole('heading', { name: /^Sync paused$/i })).toBeTruthy();
    expect(screen.getByTestId('canonical-invariant')).toBeTruthy();
  });

  it('requires confirmation before replacing a rejected installation key', () => {
    const rotateIdentity = vi.fn(async () => {});
    useShellStore.setState({ bridge: { accountStatus: async () => rejectedIdentity } as never });
    useAccountStore.setState({ rotateIdentity, data: rejectedIdentity });
    render(<AccountSurface />);

    fireEvent.click(screen.getByRole('button', { name: /Replace installation key/i }));
    expect(screen.getByRole('group', { name: /Confirm installation key replacement/i })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /Confirm key replacement/i }));
    expect(rotateIdentity).toHaveBeenCalledOnce();
  });

  it.each(['authorization_failed', 'cloud_unavailable', 'cloud_response_invalid'])(
    'offers retry sign-in for recoverable unavailable detail %s',
    (detail) => {
      const beginSignIn = vi.fn(async () => {});
      useShellStore.setState({ bridge: { accountStatus: async () => signedOut } as never });
      useAccountStore.setState({
        beginSignIn,
        data: { ...signedOut, state: 'unavailable', detail }
      });
      render(<AccountSurface />);

      const retry = screen.getByRole('button', { name: /Retry sign-in/i });
      expect((retry as HTMLButtonElement).disabled).toBe(false);
      fireEvent.click(retry);
      expect(beginSignIn).toHaveBeenCalledOnce();
    }
  );

  it('treats an App Check allowlist rejection as a build configuration failure, not a key rejection', () => {
    setAccount({
      data: {
        ...signedOut,
        state: 'unavailable',
        signedIn: true,
        detail: 'app_check_configuration_rejected'
      }
    });
    render(<AccountSurface />);

    expect(screen.getByRole('alert').textContent).toMatch(/not allowlisted/i);
    expect(screen.queryByRole('button', { name: /Replace installation key/i })).toBeNull();
  });

  it('does not present a stale identity or sign-out control for an unavailable daemon phase', () => {
    setAccount({
      data: {
        ...signedOut,
        state: 'unavailable',
        signedIn: true,
        identityLabel: 'stale@example.com',
        syncState: 'active',
        detail: 'refreshing'
      }
    });
    render(<AccountSurface />);

    expect(screen.queryByText('stale@example.com', { selector: 'strong' })).toBeNull();
    expect(screen.queryByRole('button', { name: /^Sign out$/i })).toBeNull();
    expect(screen.getByText(/Plan · Local/i)).toBeTruthy();
    expect(screen.getByRole('alert').textContent).toMatch(/temporarily unavailable/i);
  });

  it('keeps replacement progress visible until identity rotation settles', async () => {
    const rotation = deferred<AccountStatus>();
    const accountRotateIdentity = vi.fn(() => rotation.promise);
    useShellStore.setState({
      bridge: { accountRotateIdentity, accountStatus: async () => rejectedIdentity } as never
    });
    useAccountStore.setState({ data: rejectedIdentity });
    render(<AccountSurface />);

    fireEvent.click(screen.getByRole('button', { name: /Replace installation key/i }));
    fireEvent.click(screen.getByRole('button', { name: /Confirm key replacement/i }));

    expect(screen.getByRole('button', { name: /Replacing key/i })).toBeTruthy();
    expect(screen.getByRole('group', { name: /Confirm installation key replacement/i })).toBeTruthy();

    rotation.resolve(awaitingApproval);
    await waitFor(() => {
      expect(screen.queryByRole('group', { name: /Confirm installation key replacement/i })).toBeNull();
    });
  });

  it('renders loading state', () => {
    setAccount({ loading: true });
    render(<AccountSurface />);
    expect(screen.getByText(/Loading account and sync posture/i)).toBeTruthy();
  });

  it('makes an expired browser authorization actionable instead of presenting it as active', () => {
    const cancelSignIn = vi.fn(async () => {});
    const expiredAuthorization: AccountStatus = {
      ...signedOut,
      state: 'authorizing',
      authorizationOperationID: 'expired-operation',
      authorizationExpiresAt: new Date(Date.now() - 1_000).toISOString()
    };
    useAccountStore.setState({ data: expiredAuthorization, cancelSignIn });
    render(<AccountSurface />);

    expect(screen.getByText(/Browser sign-in expired\. Cancel this request/i)).toBeTruthy();
    expect(document.querySelector('.account-status-announcer')?.textContent).not.toMatch(/in progress/i);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel expired sign-in' }));
    expect(cancelSignIn).toHaveBeenCalledOnce();
  });

  it('stops the authorization poll after the daemon-provided deadline', async () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date());
      const load = vi.fn(async () => {});
      const expiresAt = new Date(Date.now() + 5_000).toISOString();
      useAccountStore.setState({
        data: {
          ...signedOut,
          state: 'authorizing',
          authorizationOperationID: 'expiring-operation',
          authorizationExpiresAt: expiresAt
        },
        load
      });
      render(<AccountSurface />);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(5_100);
      });
      expect(screen.getByText(/Browser sign-in expired\. Cancel this request/i)).toBeTruthy();
      const callsAfterExpiry = load.mock.calls.length;
      await act(async () => {
        await vi.advanceTimersByTimeAsync(6_000);
      });
      expect(load.mock.calls.length).toBe(callsAfterExpiry);
    } finally {
      vi.useRealTimers();
    }
  });

  it('renders error state with banner', () => {
    useShellStore.setState({ bridge: { accountStatus: async () => signedInActive } as never });
    setAccount({ error: 'Daemon RPC failed', data: null });
    render(<AccountSurface />);
    expect(screen.getByRole('alert').textContent).toContain('Daemon RPC failed');
  });

  it('renders offline when packaged shell is unavailable', () => {
    setAccount({ error: 'Packaged shell required for live data.', data: null });
    render(<AccountSurface />);
    expect(screen.getByText(/packaged Linux shell/i)).toBeTruthy();
    expect(screen.getByTestId('canonical-invariant')).toBeTruthy();
  });

  it('exposes stable failure-state ids', () => {
    setAccount({ data: signedOut });
    const { container } = render(<AccountSurface />);
    expect(container.querySelector('[data-failure-state="login-required"]')).not.toBeNull();
    expect(container.querySelector('[data-failure-state="sync-paused"]')).not.toBeNull();
    expect(container.querySelector('[data-failure-state="quota-exhausted"]')).not.toBeNull();
  });

  it('Check again calls store.load', () => {
    const load = vi.fn(async () => {});
    useAccountStore.setState({ load, data: signedOut });
    render(<AccountSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Check again/i }));
    expect(load).toHaveBeenCalled();
  });

  it('starts browser-mediated sign-in from the signed-out state', () => {
    const beginSignIn = vi.fn(async () => {});
    useShellStore.setState({ bridge: { accountStatus: async () => signedOut } as never });
    useAccountStore.setState({ beginSignIn, data: signedOut });
    render(<AccountSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Sign in$/i }));
    expect(beginSignIn).toHaveBeenCalledOnce();
  });

  it('surfaces trusted-iPad approval with copyable public verification values only', async () => {
    useShellStore.setState({ bridge: { accountStatus: async () => awaitingApproval } as never });
    setAccount({ data: awaitingApproval });
    const { container } = render(<AccountSurface />);
    expect(screen.getByText(/trusted OpenBurnBar device/i)).toBeTruthy();
    expect(screen.getByText(/Approval pending on a trusted device/i)).toBeTruthy();
    expect(document.querySelector('[data-device-trust-state="pending"]')).not.toBeNull();
    expect(screen.getByText(awaitingApproval.installationDeviceID!)).toBeTruthy();
    expect(screen.getByText(awaitingApproval.installationSafetyFingerprint!)).toBeTruthy();
    // Device-approval is a daemon-owned enrollment phase, not a cancellable
    // browser operation; the native cancel RPC rejects this state.
    expect(screen.queryByRole('button', { name: /Cancel sign-in/i })).toBeNull();
    const writeText = vi.fn(async () => {});
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } });
    fireEvent.click(screen.getByRole('button', { name: 'Copy fingerprint' }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(awaitingApproval.installationSafetyFingerprint));
    expect(screen.getByText(/Compare both values on the trusted iPad/i)).toBeTruthy();
    expect(container.textContent).not.toMatch(/refreshToken|idToken|appCheckToken|publicKey|sessionGeneration/);
  });

  it('renders an actionable unavailable state and prevents sign-in', () => {
    useShellStore.setState({ bridge: { accountStatus: async () => unavailable } as never });
    setAccount({ data: unavailable });
    render(<AccountSurface />);

    expect(screen.getByRole('alert').textContent).toMatch(/unlock or repair your desktop keyring/i);
    expect(screen.getByRole('heading', { name: /Cloud sign-in is unavailable/i })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Sign in$/i })).toBeNull();
    expect((screen.getByRole('button', { name: /Sign in unavailable/i }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: /Check again/i }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('requires explicit confirmation before sign-out', () => {
    const signOut = vi.fn(async () => {});
    useAccountStore.setState({ signOut, data: signedInActive });
    render(<AccountSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Sign out$/i }));
    expect(signOut).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: /Confirm sign out/i }));
    expect(signOut).toHaveBeenCalledOnce();
  });

  it('trust disclosure toggles aria-expanded and runbook link', () => {
    setAccount({ data: signedOut });
    render(<AccountSurface />);
    const toggle = screen.getByRole('button', { name: /What does lower-trust limit/i });
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    fireEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(screen.getByText(/step-up approval on a trusted device/i)).toBeTruthy();
    expect(screen.getByRole('link', { name: /Linux cloud security runbook/i })).toBeTruthy();
  });

  it('announces status politely', () => {
    setAccount({ data: signedInActive });
    render(<AccountSurface />);
    const live = document.querySelector('[aria-live="polite"]');
    expect(live?.textContent).toMatch(/Signed in as user@example.com/i);
  });

  it('loads on mount', () => {
    const load = vi.fn(async () => {});
    useAccountStore.setState({ load });
    render(<AccountSurface />);
    expect(load).toHaveBeenCalled();
  });
});
