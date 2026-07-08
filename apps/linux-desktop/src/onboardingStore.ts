const KEY = 'openburnbar.linux.onboarding.v1';

export type OnboardingState = {
  completed: boolean;
  step: number;
  skippedSteps: number[];
  daemonAck: boolean;
  secretStoreAck: boolean;
  portalAck: boolean;
  trayLimitAck: boolean;
};

const defaultState = (): OnboardingState => ({
  completed: false,
  step: 0,
  skippedSteps: [],
  daemonAck: false,
  secretStoreAck: false,
  portalAck: false,
  trayLimitAck: false
});

export function readOnboarding(): OnboardingState {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return defaultState();
    return { ...defaultState(), ...(JSON.parse(raw) as OnboardingState) };
  } catch {
    return defaultState();
  }
}

export function writeOnboarding(patch: Partial<OnboardingState>): OnboardingState {
  const next = { ...readOnboarding(), ...patch };
  localStorage.setItem(KEY, JSON.stringify(next));
  return next;
}