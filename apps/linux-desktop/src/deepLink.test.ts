import { describe, expect, it } from 'vitest';
import { decodeLinuxDeepLinkHandoff } from './tauriBridge.js';

describe('Linux deep-link handoff decoder', () => {
  it('accepts a native membership handoff without query data', () => {
    expect(
      decodeLinuxDeepLinkHandoff({
        kind: 'membership',
        route: 'account',
        outcome: 'success',
        parameters: {}
      })
    ).toEqual({
      kind: 'membership',
      route: 'account',
      outcome: 'success',
      parameters: {}
    });
  });

  it('accepts only the bounded OAuth callback parameter set', () => {
    expect(
      decodeLinuxDeepLinkHandoff({
        kind: 'oauth',
        route: 'account',
        outcome: 'callback',
        parameters: { code: 'code-1', state: 'state-1' }
      })
    ).toMatchObject({ kind: 'oauth', route: 'account', outcome: 'callback' });
  });

  it.each([
    { kind: 'membership', route: 'settings', outcome: 'success', parameters: {} },
    { kind: 'membership', route: 'account', outcome: 'callback', parameters: {} },
    { kind: 'oauth', route: 'account', outcome: 'callback', parameters: { code: 'only' } },
    { kind: 'oauth', route: 'account', outcome: 'callback', parameters: { state: 'only' } },
    { kind: 'oauth', route: 'account', outcome: 'callback', parameters: { code: 'c\n', state: 's' } },
    { kind: 'oauth', route: 'account', outcome: 'callback', parameters: { code: 'c', state: 's', redirect: 'evil' } },
    { kind: 'membership', route: 'account', outcome: 'cancel', parameters: { code: 'unexpected' } }
  ])('rejects an invalid or over-broad handoff: %j', (value) => {
    expect(() => decodeLinuxDeepLinkHandoff(value)).toThrow(/invalid linux/i);
  });

  it('rejects non-object payloads instead of trusting renderer data', () => {
    expect(() => decodeLinuxDeepLinkHandoff('openburnbar://membership/success')).toThrow(/invalid linux/i);
    expect(decodeLinuxDeepLinkHandoff(null)).toBeNull();
  });
});
