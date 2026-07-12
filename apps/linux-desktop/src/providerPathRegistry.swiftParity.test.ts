import { describe, expect, it } from 'vitest';
import { LINUX_PROVIDER_PATH_REGISTRY } from './providerPathRegistry.js';

describe('generated provider capability parity', () => {
  it('contains every provider exactly once with explicit support metadata', () => {
    expect(LINUX_PROVIDER_PATH_REGISTRY).toHaveLength(33);
    expect(new Set(LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.providerCase)).size).toBe(33);
    expect(new Set(LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.providerId)).size).toBe(33);

    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      expect(row.displayName.length).toBeGreaterThan(0);
      expect(row.symlinkIdentityBehavior).toBe('standardized-logical-path');
      if (row.parserSource === null) expect(row.unsupportedReasons.localLogs).toBeTruthy();
      if (!row.quota) expect(row.unsupportedReasons.quota).toBeTruthy();
      if (row.chatRuntimeId === null) expect(row.unsupportedReasons.chat).toBeTruthy();
      if (!row.accountConnect) expect(row.unsupportedReasons.accountConnect).toBeTruthy();
    }
  });
});
