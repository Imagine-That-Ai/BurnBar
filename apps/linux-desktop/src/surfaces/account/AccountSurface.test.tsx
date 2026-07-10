// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountStatus } from '../../tauriBridge.js';
import { useAccountStore } from '../../state/accountStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { accountPlanTier } from './accountPlanTier.js';
import { AccountSurface } from './AccountSurface.js';

function resetStores(): void {
  useAccountStore.setState({
    data: null,
    loading: false,
    error: null,
    authPhase: 'idle',
    authSession: null,
    authError: null,
    browserError: null
  });
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

const signedOut: AccountStatus = {
  state: 'signed_out',
  signedIn: false,
  trustClass: 'linux-lower-trust',
  syncState: 'local-only',
  updatedAt: '2026-07-10T00:00:00Z'
};

const signedInActive: AccountStatus = {
  state: 'signed_in',
  signedIn: true,
  uid: 'test-user',
  identityLabel: 'user@example.com',
  trustClass: 'linux-lower-trust',
  syncState: 'active',
  updatedAt: '2026-07-10T00:00:00Z',
  lastSyncAt: new Date(Date.now() - 3_600_000).toISOString()
};

const signedInPaused: AccountStatus = {
  state: 'signed_in',
  signedIn: true,
  uid: 'test-user',
  identityLabel: 'user@example.com',
  trustClass: 'linux-lower-trust',
  syncState: 'paused',
  updatedAt: '2026-07-10T00:00:00Z'
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
  });

  it('renders signed-in paused sync', () => {
    setAccount({ data: signedInPaused });
    render(<AccountSurface />);
    expect(screen.getByRole('heading', { name: /^Sync paused$/i })).toBeTruthy();
    expect(screen.getByTestId('canonical-invariant')).toBeTruthy();
  });

  it('renders loading state', () => {
    setAccount({ loading: true });
    render(<AccountSurface />);
    expect(screen.getByText(/Loading account and sync posture/i)).toBeTruthy();
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

  it('starts browser sign-in from the signed-out account card', () => {
    const startDeviceAuth = vi.fn(async () => {});
    useAccountStore.setState({ data: signedOut, startDeviceAuth });
    render(<AccountSurface />);
    fireEvent.click(screen.getAllByRole('button', { name: /Sign in with browser/i })[0]!);
    expect(startDeviceAuth).toHaveBeenCalledTimes(1);
  });

  it('shows the pending code with accessible copy, reopen, and cancel actions', async () => {
    const reopenDeviceAuth = vi.fn(async () => {});
    const cancelDeviceAuth = vi.fn(async () => {});
    const writeText = vi.fn(async () => {});
    Object.assign(navigator, { clipboard: { writeText } });
    useAccountStore.setState({
      data: signedOut,
      authPhase: 'pending',
      authSession: {
        flowId: 'flow-1',
        userCode: 'ABCD-EFGH',
        verificationUrl: 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH',
        expiresAt: '2026-07-10T12:10:00Z',
        pollIntervalSeconds: 5
      },
      reopenDeviceAuth,
      cancelDeviceAuth
    });
    render(<AccountSurface />);
    expect(screen.getByRole('heading', { name: /Finish sign-in in your browser/i })).toBeTruthy();
    expect(screen.getByLabelText(/One-time sign-in code ABCD-EFGH/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /Copy code/i }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('ABCD-EFGH'));
    fireEvent.click(screen.getByRole('button', { name: /Open browser again/i }));
    fireEvent.click(screen.getByRole('button', { name: /Cancel sign-in/i }));
    expect(reopenDeviceAuth).toHaveBeenCalledTimes(1);
    expect(cancelDeviceAuth).toHaveBeenCalledTimes(1);
  });

  it('confirms sign-out and states that local data stays on the machine', async () => {
    const signOut = vi.fn(async () => {});
    useAccountStore.setState({ data: signedInActive, signOut });
    render(<AccountSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Sign out$/i }));
    expect(screen.getByText(/Local SQLite data stays on this machine/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /Confirm sign out/i }));
    await waitFor(() => expect(signOut).toHaveBeenCalledTimes(1));
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
