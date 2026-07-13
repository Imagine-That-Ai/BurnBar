import { beforeEach, describe, expect, it } from 'vitest';
import {
  configureTextExpansionConsentStorage,
  readTextExpansionConsent,
  writeTextExpansionConsent
} from './textExpansionConsent.js';

beforeEach(() => {
  localStorage.clear();
  configureTextExpansionConsentStorage(null, true);
});

describe('text expansion consent', () => {
  it('persists in-app-only acknowledgement', () => {
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    expect(readTextExpansionConsent()?.inAppOnly).toBe(true);
    expect(localStorage.length).toBe(0);
  });
});
