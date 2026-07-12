// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountStatus } from '../../tauriBridge.js';
import { useAccountStore } from '../../state/accountStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { accountPlanTier } from './accountPlanTier.js';
import { AccountSurface } from './AccountSurface.js';

function resetStores(): void {
  useAccountStore.setState({ data: null, loading: false, error: null });
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
  signedIn: false,
  trustClass: 'linux-lower-trust',
  syncState: 'local-only'
};

const signedInActive: AccountStatus = {
  signedIn: true,
  identityLabel: 'user@example.com',
  trustClass: 'linux-lower-trust',
  syncState: 'active',
  lastSyncAt: new Date(Date.now() - 3_600_000).toISOString()
};

const signedInPaused: AccountStatus = {
  signedIn: true,
  identityLabel: 'user@example.com',
  trustClass: 'linux-lower-trust',
  syncState: 'paused'
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