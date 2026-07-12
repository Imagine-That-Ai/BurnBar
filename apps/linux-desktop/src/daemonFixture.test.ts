import { describe, expect, it } from 'vitest';
import { fixtureActivationAllowed } from './daemonFixture.js';

describe('daemon fixture activation policy', () => {
  it('is unavailable in a normal production build', () => {
    expect(fixtureActivationAllowed({ development: false, explicitlyEnabled: false })).toBe(false);
  });

  it('requires an explicit evidence flag outside development', () => {
    expect(fixtureActivationAllowed({ development: false, explicitlyEnabled: true })).toBe(true);
    expect(fixtureActivationAllowed({ development: true, explicitlyEnabled: false })).toBe(true);
  });
});
