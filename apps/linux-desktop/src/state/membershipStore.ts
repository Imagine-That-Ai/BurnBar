import { create } from 'zustand';
import {
  fixtureMembershipCheckoutUrl,
  fixtureMembershipStatus,
  type MembershipFixtureState
} from '../daemonFixture.js';
import type { MembershipStatus } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { EntitlementCache } from '../../../../packages/entitlements/src/index.js';

export type MembershipPhase =
  | 'idle'
  | 'loading'
  | 'checkout-in-flight'
  | 'portal-in-flight'
  | 'restore-in-flight'
  | 'error'
  | 'offline'
  | 'capability-absent';

export type MembershipState = {
  data: MembershipStatus | null;
  phase: MembershipPhase;
  error: string | null;
  checkoutUrl: string | null;
  externalDestination: 'checkout' | 'portal' | null;
  load(): Promise<void>;
  startCheckout(): Promise<void>;
  restore(): Promise<void>;
};

const entitlementCache = new EntitlementCache<MembershipStatus>();
const CACHE_KEY = 'membership-status';
const CACHE_TTL_MS = 60_000;

function isCapabilityAbsent(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? '');
  return /capability_absent|unknown|unsupported|unrecognized|not implemented|invalid method|method not found/i.test(message);
}

function cacheStatus(data: MembershipStatus): void {
  entitlementCache.set(CACHE_KEY, data, Date.now() + CACHE_TTL_MS);
}

function fixtureState(): MembershipFixtureState {
  if (typeof window === 'undefined') return 'active';
  const param = new URLSearchParams(window.location.search).get('membershipFixture');
  if (param === 'cancelled' || param === 'paymentFailed' || param === 'offline') return param;
  return 'active';
}

export function hasActivePaidMembership(data: MembershipStatus | null): boolean {
  if (!data || data.state === 'cancelled' || data.state === 'paymentFailed' || data.state === 'offline') return false;
  return data.tier === 'pro' || data.entitlements.length > 0;
}

export const useMembershipStore = create<MembershipState>()((set, get) => ({
  data: null,
  phase: 'idle',
  error: null,
  checkoutUrl: null,
  externalDestination: null,

  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      const data = fixtureMembershipStatus(fixtureState());
      cacheStatus(data);
      set({ data, phase: data.state === 'offline' ? 'offline' : 'idle', error: null });
      return;
    }
    if (!bridge?.membershipStatus) {
      const cached = entitlementCache.get(CACHE_KEY);
      set({
        data: cached ?? null,
        phase: cached ? 'idle' : bridge ? 'capability-absent' : 'offline',
        error: cached
          ? null
          : bridge
            ? 'This daemon build does not expose Linux membership RPC yet.'
            : 'Packaged shell required for live membership data.'
      });
      return;
    }
    set({ phase: 'loading', error: null });
    try {
      const data = await bridge.membershipStatus();
      cacheStatus(data);
      set({ data, phase: data.state === 'offline' ? 'offline' : 'idle', error: null });
    } catch (e) {
      if (isCapabilityAbsent(e)) {
        set({
          data: null,
          phase: 'capability-absent',
          error: 'This daemon build does not expose Linux membership RPC yet.'
        });
        return;
      }
      set({ data: null, phase: 'error', error: e instanceof Error ? e.message : 'Membership request failed' });
    }
  },

  async startCheckout() {
    const { fixtureMode, bridge } = useShellStore.getState();
    const destination = hasActivePaidMembership(get().data) ? 'portal' : 'checkout';
    set({ phase: destination === 'portal' ? 'portal-in-flight' : 'checkout-in-flight', error: null });
    try {
      const url = fixtureMode
        ? fixtureMembershipCheckoutUrl()
        : destination === 'portal'
          ? await bridge?.membershipPortalUrl?.()
          : await bridge?.membershipCheckoutUrl?.();
      if (!url) {
        throw new Error(
          destination === 'portal'
            ? 'This daemon build does not expose Stripe billing management yet.'
            : 'Packaged shell required for Stripe checkout.'
        );
      }
      if (bridge?.openExternalUrl) await bridge.openExternalUrl(url);
      set({
        checkoutUrl: url,
        externalDestination: destination,
        phase: destination === 'portal' ? 'portal-in-flight' : 'checkout-in-flight',
        error: null
      });
    } catch (e) {
      if (isCapabilityAbsent(e)) {
        set({
          phase: 'capability-absent',
          error:
            destination === 'portal'
              ? 'This daemon build does not expose Stripe billing management yet.'
              : 'This daemon build cannot mint Stripe checkout URLs yet.'
        });
        return;
      }
      set({ phase: 'error', error: e instanceof Error ? e.message : 'Checkout failed' });
    }
  },

  async restore() {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ phase: 'restore-in-flight', error: null });
    try {
      if (!fixtureMode) {
        if (!bridge?.membershipRestore) throw new Error('This daemon build does not expose membership restore yet.');
        await bridge.membershipRestore();
      }
      await get().load();
    } catch (e) {
      if (isCapabilityAbsent(e)) {
        set({
          phase: 'capability-absent',
          error: 'This daemon build does not expose membership restore yet.'
        });
        return;
      }
      set({ phase: 'error', error: e instanceof Error ? e.message : 'Restore failed' });
    }
  }
}));

export function useEntitlement(id: string): boolean {
  return useMembershipStore((s) => Boolean(s.data?.entitlements.includes(id)));
}

export function clearMembershipEntitlementCache(): void {
  entitlementCache.clear();
}
