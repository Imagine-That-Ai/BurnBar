import { beforeEach, describe, expect, it } from 'vitest';
import {
  configureTextExpansionConsentStorage,
  hydrateTextExpansionConsentStorage,
  readTextExpansionConsent,
  textExpansionConsentError,
  writeTextExpansionConsent,
  writeTextExpansionConsentPersisted
} from './textExpansionConsent.js';
import type { TextExpansionConsent, TextExpansionSnapshot } from './tauriBridge.js';

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

  it('rolls back an optimistic enable when the daemon rejects persistence', async () => {
    const snapshot: TextExpansionSnapshot = {
      schemaVersion: 1,
      exportedAt: new Date(0).toISOString(),
      snippets: [],
      consent: null
    };
    const backend = {
      textExpansionList: async () => snapshot,
      textExpansionConsentUpdate: async () => {
        throw new Error('keyring unavailable');
      }
    };
    await hydrateTextExpansionConsentStorage(backend);
    await expect(writeTextExpansionConsentPersisted({ inAppOnly: true, declinedGlobalCapture: true }))
      .rejects.toThrow(/keyring unavailable/);
    expect(readTextExpansionConsent()).toBeNull();
    expect(textExpansionConsentError()).toMatch(/keyring unavailable/);
  });

  it('keeps system-IME revocation fail closed when persistence rejects it', async () => {
    const acknowledgedAt = new Date(0).toISOString();
    const snapshot: TextExpansionSnapshot = {
      schemaVersion: 1,
      exportedAt: acknowledgedAt,
      snippets: [],
      consent: {
        inAppOnly: true,
        systemIMEEnabled: true,
        declinedGlobalCapture: true,
        acknowledgedAt
      }
    };
    const backend = {
      textExpansionList: async () => snapshot,
      textExpansionConsentUpdate: async () => {
        throw new Error('keyring unavailable');
      }
    };
    await hydrateTextExpansionConsentStorage(backend);

    await expect(writeTextExpansionConsentPersisted({
      inAppOnly: true,
      systemIMEEnabled: false,
      declinedGlobalCapture: true
    })).rejects.toThrow(/keyring unavailable/);
    expect(readTextExpansionConsent()).toMatchObject({
      inAppOnly: true,
      systemIMEEnabled: false
    });
  });

  it('ignores a late write from a replaced daemon backend', async () => {
    let release!: (value: { inAppOnly: boolean; acknowledgedAt: string; declinedGlobalCapture: boolean }) => void;
    const snapshot: TextExpansionSnapshot = {
      schemaVersion: 1,
      exportedAt: new Date(0).toISOString(),
      snippets: [],
      consent: null
    };
    const backend = {
      textExpansionList: async () => snapshot,
      textExpansionConsentUpdate: async () => new Promise<TextExpansionConsent>((resolve) => { release = resolve; })
    };
    await hydrateTextExpansionConsentStorage(backend);
    const pending = writeTextExpansionConsentPersisted({ inAppOnly: true, declinedGlobalCapture: true });
    await Promise.resolve();
    configureTextExpansionConsentStorage(null, true);
    release({ inAppOnly: true, declinedGlobalCapture: true, acknowledgedAt: new Date(1).toISOString() });
    await expect(pending).rejects.toThrow(/changed|retry/i);
    expect(readTextExpansionConsent()).toBeNull();
  });
});
