// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import {
  cacheOnboarding,
  decodeLinuxOnboardingSnapshot,
  defaultLinuxOnboardingSnapshot,
  readOnboarding,
  shouldRouteToOnboarding
} from './onboardingStore.js';

describe('daemon-owned Linux onboarding snapshot', () => {
  beforeEach(() => localStorage.clear());

  it('round-trips only the strict v2 daemon cache', () => {
    const snapshot = defaultLinuxOnboardingSnapshot();
    cacheOnboarding(snapshot);
    expect(readOnboarding()).toEqual(snapshot);
  });

  it('rejects a forged completion flag', () => {
    const snapshot = defaultLinuxOnboardingSnapshot();
    expect(() => decodeLinuxOnboardingSnapshot({ ...snapshot, completed: true })).toThrow(
      'onboarding_completion_invariant_mismatch'
    );
  });

  it('rejects reordered or requirement-downgraded steps', () => {
    const snapshot = defaultLinuxOnboardingSnapshot();
    const reordered = [...snapshot.steps];
    [reordered[0], reordered[1]] = [reordered[1], reordered[0]];
    expect(() => decodeLinuxOnboardingSnapshot({ ...snapshot, steps: reordered })).toThrow(
      'onboarding_step_contract_drift'
    );

    const downgraded = snapshot.steps.map((step) =>
      step.id === 'secret_store' ? { ...step, requirement: 'optional' } : step
    );
    expect(() => decodeLinuxOnboardingSnapshot({ ...snapshot, steps: downgraded })).toThrow(
      'onboarding_step_contract_drift'
    );
  });

  it('rejects optional-only states on required steps and future-step jumps', () => {
    const snapshot = defaultLinuxOnboardingSnapshot();
    const skippedRequired = {
      ...snapshot,
      steps: snapshot.steps.map((step) =>
        step.id === 'daemon' ? { ...step, state: 'skipped' } : step
      )
    };
    expect(() => decodeLinuxOnboardingSnapshot(skippedRequired)).toThrow(
      'onboarding_required_step_has_optional_state'
    );

    expect(() =>
      decodeLinuxOnboardingSnapshot({ ...snapshot, currentStepID: 'secret_store' })
    ).toThrow('onboarding_current_step_ahead_of_prerequisite');
  });

  it('does not trust the legacy browser-only completion key', () => {
    localStorage.setItem('openburnbar.linux.onboarding.v1', JSON.stringify({ completed: true }));
    expect(readOnboarding().completed).toBe(false);
  });

  it('forces setup when daemon authority is missing or incomplete', () => {
    const pending = defaultLinuxOnboardingSnapshot();
    const completed: typeof pending = {
      ...pending,
      currentStepID: 'privacy',
      steps: pending.steps.map((step) => ({
        ...step,
        state: step.requirement === 'required' ? 'verified' : 'skipped'
      })),
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      completed: true
    };

    expect(shouldRouteToOnboarding(null)).toBe(true);
    expect(shouldRouteToOnboarding(pending)).toBe(true);
    expect(shouldRouteToOnboarding(completed)).toBe(false);
  });
});
