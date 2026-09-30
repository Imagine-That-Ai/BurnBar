import { describe, expect, it } from 'vitest';
import { mapMembershipPortalUrl } from '../tauriBridgeSystemDecoders.js';

describe('membership billing routing', () => {
  it('decodes the daemon portal response and rejects a missing URL', () => {
    expect(mapMembershipPortalUrl({ url: 'https://billing.stripe.com/p/session/member_123' })).toBe(
      'https://billing.stripe.com/p/session/member_123'
    );
    expect(() => mapMembershipPortalUrl({ source: 'stripe_billing_portal' })).toThrow(
      /did not return a Stripe billing portal URL/i
    );
  });
});
