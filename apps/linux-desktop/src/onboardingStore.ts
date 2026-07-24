const CACHE_KEY = 'openburnbar.linux.onboarding.cache.v2';

export const LINUX_ONBOARDING_STEP_IDS = [
  'daemon',
  'secret_store',
  'provider_paths',
  'cloud_identity',
  'portal_input',
  'tray',
  'updates',
  'privacy'
] as const;

export type LinuxOnboardingStepId = (typeof LINUX_ONBOARDING_STEP_IDS)[number];
export type LinuxOnboardingRequirement = 'required' | 'optional';
export type LinuxOnboardingStepState =
  | 'pending'
  | 'blocked'
  | 'verified'
  | 'acknowledged'
  | 'skipped';

export type LinuxOnboardingRepairAction =
  | 'start_daemon'
  | 'unlock_secret_store'
  | 'repair_provider_data'
  | 'sign_in'
  | 'grant_portal'
  | 'enable_tray'
  | 'open_updates'
  | 'choose_privacy'
  | 'retry';

export type LinuxOnboardingStepSnapshot = {
  id: LinuxOnboardingStepId;
  requirement: LinuxOnboardingRequirement;
  state: LinuxOnboardingStepState;
  attemptCount: number;
  detail?: string;
  verifiedAt?: string;
  repairAction?: LinuxOnboardingRepairAction;
};

export type LinuxOnboardingPrivacyChoices = {
  telemetryEnabled: boolean;
  cloudSyncEnabled: boolean;
};

export type LinuxOnboardingSnapshot = {
  schemaVersion: 1;
  revision: number;
  currentStepID: LinuxOnboardingStepId;
  steps: LinuxOnboardingStepSnapshot[];
  privacyChoices?: LinuxOnboardingPrivacyChoices;
  completed: boolean;
  updatedAt: string;
};

export type LinuxOnboardingAction =
  | 'verify'
  | 'acknowledge'
  | 'skip'
  | 'navigate'
  | 'save_privacy_choices';

export type LinuxOnboardingActionRequest = {
  stepID: LinuxOnboardingStepId;
  action: LinuxOnboardingAction;
  telemetryEnabled?: boolean;
  cloudSyncEnabled?: boolean;
};

const REQUIREMENTS: Record<LinuxOnboardingStepId, LinuxOnboardingRequirement> = {
  daemon: 'required',
  secret_store: 'required',
  provider_paths: 'required',
  cloud_identity: 'optional',
  portal_input: 'optional',
  tray: 'optional',
  updates: 'optional',
  privacy: 'required'
};

const STEP_STATES = new Set<LinuxOnboardingStepState>([
  'pending',
  'blocked',
  'verified',
  'acknowledged',
  'skipped'
]);
const REPAIR_ACTIONS = new Set<LinuxOnboardingRepairAction>([
  'start_daemon',
  'unlock_secret_store',
  'repair_provider_data',
  'sign_in',
  'grant_portal',
  'enable_tray',
  'open_updates',
  'choose_privacy',
  'retry'
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isStepId(value: unknown): value is LinuxOnboardingStepId {
  return typeof value === 'string' && LINUX_ONBOARDING_STEP_IDS.includes(value as LinuxOnboardingStepId);
}

function computedCompletion(steps: LinuxOnboardingStepSnapshot[]): boolean {
  return steps.every((step) =>
    step.requirement === 'required'
      ? step.state === 'verified'
      : step.state === 'verified' || step.state === 'acknowledged' || step.state === 'skipped'
  );
}

function isTerminal(step: LinuxOnboardingStepSnapshot): boolean {
  return step.requirement === 'required'
    ? step.state === 'verified'
    : step.state === 'verified' || step.state === 'acknowledged' || step.state === 'skipped';
}

/** Strict decoder for the daemon-owned completion invariant. */
export function decodeLinuxOnboardingSnapshot(raw: unknown): LinuxOnboardingSnapshot {
  if (!isRecord(raw) || raw.schemaVersion !== 1) {
    throw new Error('onboarding_invalid_schema');
  }
  if (!Number.isSafeInteger(raw.revision) || Number(raw.revision) < 0) {
    throw new Error('onboarding_invalid_revision');
  }
  if (!isStepId(raw.currentStepID) || !Array.isArray(raw.steps)) {
    throw new Error('onboarding_invalid_current_step');
  }
  if (raw.steps.length !== LINUX_ONBOARDING_STEP_IDS.length) {
    throw new Error('onboarding_invalid_step_count');
  }

  const steps = raw.steps.map((value, index): LinuxOnboardingStepSnapshot => {
    if (!isRecord(value)) throw new Error('onboarding_invalid_step');
    const expectedId = LINUX_ONBOARDING_STEP_IDS[index];
    if (value.id !== expectedId || value.requirement !== REQUIREMENTS[expectedId]) {
      throw new Error('onboarding_step_contract_drift');
    }
    if (typeof value.state !== 'string' || !STEP_STATES.has(value.state as LinuxOnboardingStepState)) {
      throw new Error('onboarding_invalid_step_state');
    }
    if (
      value.requirement === 'required' &&
      (value.state === 'acknowledged' || value.state === 'skipped')
    ) {
      throw new Error('onboarding_required_step_has_optional_state');
    }
    if (!Number.isSafeInteger(value.attemptCount) || Number(value.attemptCount) < 0) {
      throw new Error('onboarding_invalid_attempt_count');
    }
    if (value.detail !== undefined && typeof value.detail !== 'string') {
      throw new Error('onboarding_invalid_detail');
    }
    if (value.verifiedAt !== undefined && typeof value.verifiedAt !== 'string') {
      throw new Error('onboarding_invalid_verified_at');
    }
    if (
      value.repairAction !== undefined &&
      (typeof value.repairAction !== 'string' ||
        !REPAIR_ACTIONS.has(value.repairAction as LinuxOnboardingRepairAction))
    ) {
      throw new Error('onboarding_invalid_repair_action');
    }
    return {
      id: expectedId,
      requirement: REQUIREMENTS[expectedId],
      state: value.state as LinuxOnboardingStepState,
      attemptCount: Number(value.attemptCount),
      ...(typeof value.detail === 'string' ? { detail: value.detail } : {}),
      ...(typeof value.verifiedAt === 'string' ? { verifiedAt: value.verifiedAt } : {}),
      ...(typeof value.repairAction === 'string'
        ? { repairAction: value.repairAction as LinuxOnboardingRepairAction }
        : {})
    };
  });

  const currentStepIndex = LINUX_ONBOARDING_STEP_IDS.indexOf(raw.currentStepID);
  const firstUnresolvedIndex = steps.findIndex((step) => !isTerminal(step));
  if (firstUnresolvedIndex >= 0 && currentStepIndex > firstUnresolvedIndex) {
    throw new Error('onboarding_current_step_ahead_of_prerequisite');
  }

  let privacyChoices: LinuxOnboardingPrivacyChoices | undefined;
  if (raw.privacyChoices !== undefined) {
    if (
      !isRecord(raw.privacyChoices) ||
      typeof raw.privacyChoices.telemetryEnabled !== 'boolean' ||
      typeof raw.privacyChoices.cloudSyncEnabled !== 'boolean'
    ) {
      throw new Error('onboarding_invalid_privacy_choices');
    }
    privacyChoices = {
      telemetryEnabled: raw.privacyChoices.telemetryEnabled,
      cloudSyncEnabled: raw.privacyChoices.cloudSyncEnabled
    };
  }

  const privacyVerified = steps.find((step) => step.id === 'privacy')?.state === 'verified';
  if (privacyVerified && !privacyChoices) throw new Error('onboarding_missing_privacy_choices');
  if (typeof raw.completed !== 'boolean' || raw.completed !== computedCompletion(steps)) {
    throw new Error('onboarding_completion_invariant_mismatch');
  }
  if (typeof raw.updatedAt !== 'string' || raw.updatedAt.length === 0) {
    throw new Error('onboarding_invalid_updated_at');
  }

  return {
    schemaVersion: 1,
    revision: Number(raw.revision),
    currentStepID: raw.currentStepID,
    steps,
    ...(privacyChoices ? { privacyChoices } : {}),
    completed: raw.completed,
    updatedAt: raw.updatedAt
  };
}

export function defaultLinuxOnboardingSnapshot(): LinuxOnboardingSnapshot {
  return {
    schemaVersion: 1,
    revision: 0,
    currentStepID: 'daemon',
    steps: LINUX_ONBOARDING_STEP_IDS.map((id) => ({
      id,
      requirement: REQUIREMENTS[id],
      state: 'pending',
      attemptCount: 0
    })),
    completed: false,
    updatedAt: new Date(0).toISOString()
  };
}

/** Missing or incomplete daemon authority always keeps the shell in setup. */
export function shouldRouteToOnboarding(
  authoritative: LinuxOnboardingSnapshot | null
): boolean {
  return authoritative?.completed !== true;
}

/**
 * Browser cache only. The packaged app always replaces this with a daemon RPC
 * response before treating completion as authoritative.
 */
export function readOnboarding(): LinuxOnboardingSnapshot {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    return raw ? decodeLinuxOnboardingSnapshot(JSON.parse(raw)) : defaultLinuxOnboardingSnapshot();
  } catch {
    return defaultLinuxOnboardingSnapshot();
  }
}

export function cacheOnboarding(snapshot: LinuxOnboardingSnapshot): void {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(decodeLinuxOnboardingSnapshot(snapshot)));
  } catch {
    // Browser cache is advisory; daemon-owned state remains authoritative.
  }
}
