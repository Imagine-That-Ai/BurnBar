import { beforeEach, describe, expect, it } from 'vitest';
import { readTextExpansionConsent, writeTextExpansionConsent } from './textExpansionConsent.js';

beforeEach(() => {
  localStorage.clear();
});

describe('text expansion consent', () => {
  it('persists in-app-only acknowledgement', () => {
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    expect(readTextExpansionConsent()?.inAppOnly).toBe(true);
  });
});