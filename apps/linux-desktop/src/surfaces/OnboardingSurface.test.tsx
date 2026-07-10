// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { defaultLinuxOnboardingSnapshot, type LinuxOnboardingSnapshot } from '../onboardingStore.js';
import { resetAccountStoreForTests } from '../state/accountStore.js';
import { useShellStore } from '../state/shellStore.js';
import { bridgeStubDefaults } from '../testing/bridgeStubs.js';
import type { LinuxShellBridge } from '../tauriBridge.js';
import { OnboardingSurface } from './OnboardingSurface.js';

function cloudIdentitySnapshot(): LinuxOnboardingSnapshot {
  const initial = defaultLinuxOnboardingSnapshot();
  return {
    ...initial,
    revision: 3,
    currentStepID: 'cloud_identity',
    updatedAt: '2026-07-10T12:00:00Z',
    steps: initial.steps.map((step, index) => index < 3
      ? { ...step, state: 'verified', attemptCount: 1, verifiedAt: '2026-07-10T12:00:00Z' }
      : step)
  };
}

describe('OnboardingSurface account integration', () => {
  beforeEach(() => {
    localStorage.clear();
    resetAccountStoreForTests();
    const snapshot = cloudIdentitySnapshot();
    const bridge = {
      ...bridgeStubDefaults,
      onboardingSnapshot: async () => snapshot,
      accountStatus: async () => ({
        state: 'signed_out',
        signedIn: false,
        trustClass: 'linux-lower-trust',
        syncState: 'local-only',
        updatedAt: '2026-07-10T12:00:00Z'
      })
    } as unknown as LinuxShellBridge;
    useShellStore.setState({ bridge, bridgeReady: true, fixtureMode: false });
  });

  afterEach(() => {
    cleanup();
    resetAccountStoreForTests();
  });

  it('offers the reusable browser sign-in flow while preserving local-mode skip', async () => {
    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: /Cloud identity & sync trust/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /Sign in with browser/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /Skip for now/i })).toBeTruthy();
    expect(screen.getByText(/encrypted sync only resumes after explicit login/i)).toBeTruthy();
  });
});
