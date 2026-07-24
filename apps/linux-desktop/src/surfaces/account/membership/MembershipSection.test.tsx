// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { bridgeStubDefaults } from '../../../testing/bridgeStubs.js';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureMembershipStatus } from '../../../daemonFixture.js';
import {
  clearMembershipEntitlementCache,
  hasActivePaidMembership,
  useEntitlement,
  useMembershipStore
} from '../../../state/membershipStore.js';
import { useShellStore } from '../../../state/shellStore.js';
import type { LinuxShellBridge, MembershipStatus } from '../../../tauriBridge.js';
import { MembershipSection } from './MembershipSection.js';

function resetStores(): void {
  clearMembershipEntitlementCache();
  window.history.replaceState({}, '', '/');
  useMembershipStore.setState({
    data: null,
    phase: 'idle',
    error: null,
    checkoutUrl: null,
    externalDestination: null
  });
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    bridgeReady: true,
    health: null,
    healthError: null,
    healthBusy: false
  });
}

function bridge(partial: Partial<LinuxShellBridge>): LinuxShellBridge {
  return {
    ...bridgeStubDefaults,
    daemonHealth: async () => ({ ok: true }),
    openDashboard: async () => {},
    quitApp: async () => {},
    trayDegraded: async () => false,
    measurePerfOperation: async (name: string) => ({ name, ms: 1, source: 'test', ok: true }),
    usageSummary: async () => ({ todayTokens: 0, todayCostUsd: 0, sevenDay: [], recentEvents: [] }),
    providerCatalog: async () => [],
    sessionList: async () => ({ sessions: [], nextCursor: null }),
    sessionSearch: async () => ({ sessions: [], nextCursor: null }),
    usageInsights: async () => ({ weekly: [], providerMix: [], modelMix: [], cacheHitRatePct: 0 }),
    missionList: async () => ({ missions: [], pendingApprovals: [] }),
    missionApprovalDecision: async () => {},
    configSnapshot: async () => ({
      paths: { supportDir: '', socketPath: '', configDir: '', providerLogPaths: [] },
      secretServiceStatus: 'unknown',
      telemetryEnabled: false,
      privacyOptIn: false
    }),
    dbStatus: async () => ({ sqlcipherOk: false, migrationVersion: 0, sizeBytes: 0, walMode: false }),
    projectList: async () => [],
    memoryBoundaries: async () => [],
    accountStatus: async () => ({ signedIn: false, trustClass: 'linux-lower-trust', syncState: 'local-only' }),
    appVersionInfo: async () => ({ shellVersion: '', daemonVersion: '', packageChannel: 'unknown', updateCheck: '' }),
    exportDiagnostics: async () => ({ path: '' }),
    sessionEnv: async () => ({}),
    ...partial,
    accountBeginSignIn: partial.accountBeginSignIn ?? bridgeStubDefaults.accountBeginSignIn,
    accountCancelSignIn: partial.accountCancelSignIn ?? bridgeStubDefaults.accountCancelSignIn,
    accountRotateIdentity: partial.accountRotateIdentity ?? bridgeStubDefaults.accountRotateIdentity,
    accountSignOut: partial.accountSignOut ?? bridgeStubDefaults.accountSignOut,
    onboardingSnapshot: partial.onboardingSnapshot ?? bridgeStubDefaults.onboardingSnapshot,
    onboardingAction: partial.onboardingAction ?? bridgeStubDefaults.onboardingAction,
    onboardingReset: partial.onboardingReset ?? bridgeStubDefaults.onboardingReset
  };
}

function HookProbe({ id }: { id: string }) {
  return <span data-testid="entitlement-probe">{useEntitlement(id) ? 'yes' : 'no'}</span>;
}

describe('MembershipSection', () => {
  beforeEach(resetStores);
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('renders Pro fixture state and exposes the entitlement hook', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(
      <>
        <MembershipSection />
        <HookProbe id="burnbar_pro" />
      </>
    );
    expect(await screen.findByText(/Cloud Pro member/i)).toBeTruthy();
    expect(screen.getByText(/Data source: fixture transcript/i)).toBeTruthy();
    expect(screen.getByText('BurnBar Pro').closest('.membership-entitlement-row')?.textContent).toContain('Active');
    expect(screen.getByTestId('entitlement-probe').textContent).toBe('yes');
    expect(screen.queryByTestId('membership-veiled-content')).toBeNull();
  });

  it('recognizes active paid entitlement families without relying on the legacy pro tier string', () => {
    expect(
      hasActivePaidMembership({
        tier: 'free',
        entitlements: ['burnbar_ultra'],
        restoreAvailable: true,
        state: 'active'
      })
    ).toBe(true);
    expect(
      hasActivePaidMembership({
        tier: 'pro',
        entitlements: ['burnbar_pro'],
        restoreAvailable: true,
        state: 'cancelled'
      })
    ).toBe(false);
  });

  it('renders the loading state while daemon membership is pending', async () => {
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: () => new Promise<MembershipStatus>(() => {})
      })
    });
    render(<MembershipSection />);
    expect(await screen.findByText(/Checking daemon membership status/i)).toBeTruthy();
    expect(screen.getByText(/Data source: live daemon/i)).toBeTruthy();
  });

  it('renders cancelled fixture as free with inert locked content', async () => {
    useShellStore.setState({ fixtureMode: true });
    window.history.replaceState({}, '', '/?membershipFixture=cancelled');
    render(<MembershipSection />);
    expect(await screen.findByText(/Free local member/i)).toBeTruthy();
    expect(screen.getByText(/Cancelled/i)).toBeTruthy();
    const veiled = screen.getByTestId('membership-veiled-content');
    expect(veiled.hasAttribute('inert')).toBe(true);
    expect(veiled.getAttribute('aria-hidden')).toBe('true');
    expect(veiled.getAttribute('tabindex')).toBe('-1');
    await waitFor(() => {
      const veiledButtons = Array.from(veiled.querySelectorAll('button'));
      expect(veiledButtons.length).toBeGreaterThan(0);
      expect(veiledButtons.every((button) => button.getAttribute('tabindex') === '-1')).toBe(true);
    });
  });

  it('renders a daemon free state as empty membership with locked entitlements', async () => {
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => ({
          tier: 'free',
          entitlements: [],
          restoreAvailable: true,
          cacheEvent: 'membership.entitlement_cache.updated'
        })
      })
    });
    render(<MembershipSection />);
    expect(await screen.findByText(/Free local member/i)).toBeTruthy();
    expect(screen.getByText(/Data source: live daemon/i)).toBeTruthy();
    expect(screen.getByText('BurnBar Pro').closest('.membership-entitlement-row')?.textContent).toContain('Locked');
    expect(screen.getByTestId('membership-veiled-content')).toBeTruthy();
  });

  it('renders payment-failed and offline fixture states', async () => {
    useShellStore.setState({ fixtureMode: true });
    window.history.replaceState({}, '', '/?membershipFixture=paymentFailed');
    render(<MembershipSection />);
    expect(await screen.findByText(/Payment failed/i)).toBeTruthy();

    cleanup();
    resetStores();
    useShellStore.setState({ fixtureMode: true });
    window.history.replaceState({}, '', '/?membershipFixture=offline');
    render(<MembershipSection />);
    expect(await screen.findByText(/Offline · Renewal date unavailable/i)).toBeTruthy();
  });

  it('opens checkout externally and returns to a recoverable opened state', async () => {
    const openExternalUrl = vi.fn(async () => {});
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => fixtureMembershipStatus('cancelled'),
        membershipCheckoutUrl: async () => 'https://checkout.stripe.test/session/cs_test_packet',
        openExternalUrl
      })
    });
    render(<MembershipSection />);
    await screen.findByText(/Free local member/i);
    fireEvent.click(screen.getByRole('button', { name: /Open checkout/i }));
    await waitFor(() =>
      expect(openExternalUrl).toHaveBeenCalledWith('https://checkout.stripe.test/session/cs_test_packet')
    );
    expect(screen.getByText(/Stripe checkout is open in your browser/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: /Re-check membership/i })).toBeTruthy();
    expect((screen.getByRole('button', { name: /Open checkout/i }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('opens billing portal for an active member and never starts another checkout', async () => {
    const membershipCheckoutUrl = vi.fn(async () => 'https://checkout.stripe.com/c/pay/should-not-open');
    const membershipPortalUrl = vi.fn(async () => 'https://billing.stripe.com/p/session/member_123');
    const openExternalUrl = vi.fn(async () => {});
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => fixtureMembershipStatus('active'),
        membershipCheckoutUrl,
        membershipPortalUrl,
        openExternalUrl
      })
    });
    render(<MembershipSection />);
    await screen.findByText(/Cloud Pro member/i);
    fireEvent.click(screen.getByRole('button', { name: /Manage subscription/i }));
    await waitFor(() =>
      expect(openExternalUrl).toHaveBeenCalledWith('https://billing.stripe.com/p/session/member_123')
    );
    expect(membershipPortalUrl).toHaveBeenCalledTimes(1);
    expect(membershipCheckoutUrl).not.toHaveBeenCalled();
    expect(screen.getByText(/Stripe billing management is open in your browser/i)).toBeTruthy();
  });

  it('opens billing portal for an active future paid entitlement even when tier maps to free', async () => {
    const membershipCheckoutUrl = vi.fn(async () => 'https://checkout.stripe.com/c/pay/should-not-open');
    const membershipPortalUrl = vi.fn(async () => 'https://billing.stripe.com/p/session/ultra_123');
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => ({
          tier: 'free',
          entitlements: ['future_paid_family'],
          restoreAvailable: true,
          state: 'active'
        }),
        membershipCheckoutUrl,
        membershipPortalUrl,
        openExternalUrl: async () => {}
      })
    });
    render(<MembershipSection />);
    await screen.findByText(/Cloud Pro member/i);
    fireEvent.click(screen.getByRole('button', { name: /Manage subscription/i }));
    await waitFor(() => expect(membershipPortalUrl).toHaveBeenCalledTimes(1));
    expect(membershipCheckoutUrl).not.toHaveBeenCalled();
  });

  it('reports an absent portal capability without falling back to checkout', async () => {
    const membershipCheckoutUrl = vi.fn(async () => 'https://checkout.stripe.com/c/pay/should-not-open');
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => fixtureMembershipStatus('active'),
        membershipCheckoutUrl,
        membershipPortalUrl: async () => {
          throw new Error('membership_capability_absent');
        }
      })
    });
    render(<MembershipSection />);
    await screen.findByText(/Cloud Pro member/i);
    fireEvent.click(screen.getByRole('button', { name: /Manage subscription/i }));
    expect(await screen.findByText(/does not expose Stripe billing management yet/i)).toBeTruthy();
    expect(membershipCheckoutUrl).not.toHaveBeenCalled();
    expect(document.querySelector('[data-membership-phase="capability-absent"]')).toBeTruthy();
  });

  it('manual re-check re-fetches membership after checkout', async () => {
    const membershipStatus = vi.fn(async () => fixtureMembershipStatus('cancelled'));
    useShellStore.setState({
      bridge: bridge({
        membershipStatus,
        membershipCheckoutUrl: async () => 'https://checkout.stripe.test/session/cs_test_recheck',
        openExternalUrl: async () => {}
      })
    });
    render(<MembershipSection />);
    await screen.findByText(/Free local member/i);
    fireEvent.click(screen.getByRole('button', { name: /Open checkout/i }));
    await screen.findByText(/Stripe checkout is open in your browser/i);
    fireEvent.click(screen.getByRole('button', { name: /Re-check membership/i }));
    await waitFor(() => expect(membershipStatus).toHaveBeenCalledTimes(2));
  });

  it('restore calls daemon restore then re-fetches membership', async () => {
    const membershipRestore = vi.fn(async () => {});
    const membershipStatus = vi
      .fn()
      .mockResolvedValueOnce(fixtureMembershipStatus('cancelled'))
      .mockResolvedValueOnce(fixtureMembershipStatus('active')) as () => Promise<MembershipStatus>;
    useShellStore.setState({
      bridge: bridge({
        membershipStatus,
        membershipRestore
      })
    });
    render(<MembershipSection />);
    await screen.findByText(/Free local member/i);
    fireEvent.click(screen.getByRole('button', { name: /^Restore$/i }));
    await waitFor(() => expect(membershipRestore).toHaveBeenCalled());
    await waitFor(() => expect(screen.getByText(/Cloud Pro member/i)).toBeTruthy());
    expect(membershipStatus).toHaveBeenCalledTimes(2);
  });

  it('downgrades unknown membership RPC to capability-absent status', async () => {
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => {
          throw new Error('unknown method daemon.membership.status');
        }
      })
    });
    render(<MembershipSection />);
    expect(await screen.findByText(/does not expose Linux membership RPC yet/i)).toBeTruthy();
    expect(document.querySelector('[data-membership-phase="capability-absent"]')).toBeTruthy();
  });

  it('renders offline when no packaged bridge is available', async () => {
    render(<MembershipSection />);
    expect(await screen.findByText(/Packaged shell required for live membership data/i)).toBeTruthy();
    expect(screen.getByText(/Data source: offline degraded/i)).toBeTruthy();
    expect(document.querySelector('[data-membership-phase="offline"]')).toBeTruthy();
  });

  it('renders non-capability errors as alerts', async () => {
    useShellStore.setState({
      bridge: bridge({
        membershipStatus: async () => {
          throw new Error('socket timeout');
        }
      })
    });
    render(<MembershipSection />);
    expect((await screen.findByRole('alert')).textContent).toContain('socket timeout');
  });
});
