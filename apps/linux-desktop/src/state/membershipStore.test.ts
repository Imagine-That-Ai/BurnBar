import { describe, expect, it } from 'vitest';
import { mapMembershipPortalUrl } from '../tauriBridgeSystemDecoders.js';
import { hasActivePaidMembership } from './membershipStore.js';

describe('membership billing routing', () => {
  it('routes any active paid entitlement family to subscription management', () => {
    expect(
      hasActivePaidMembership({
        tier: 'free',
        entitlements: ['future_paid_family'],
        restoreAvailable: true,
        state: 'active'
      })
    ).toBe(true);
    expect(
      hasActivePaidMembership({
        tier: 'pro',
        entitlements: ['burnbar_pro'],
        restoreAvailable: true,
        state: 'paymentFailed'
      })
    ).toBe(false);
  });

  it('decodes the daemon portal response and rejects a missing URL', () => {
    expect(mapMembershipPortalUrl({ url: 'https://billing.stripe.com/p/session/member_123' })).toBe(
      'https://billing.stripe.com/p/session/member_123'
    );
    expect(() => mapMembershipPortalUrl({ source: 'stripe_billing_portal' })).toThrow(
      /did not return a Stripe billing portal URL/i
    );
  });
});
