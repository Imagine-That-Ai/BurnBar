import { create } from 'zustand';
import type {
  ProviderExternalAuthFlowSnapshot,
  ProviderExternalAuthStatusRequest
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { useProvidersStore } from './providersStore.js';
import { useSystemStore } from './systemStore.js';

const BASE_POLL_DELAY_MS = 2_000;
const MAX_POLL_DELAY_MS = 10_000;

type ProviderBusyOperation = 'loading' | 'starting' | 'cancelling';
type ActiveFlowBinding = Required<ProviderExternalAuthStatusRequest>;

export type ProviderExternalAuthState = {
  snapshots: Record<string, ProviderExternalAuthFlowSnapshot | undefined>;
  busy: Record<string, ProviderBusyOperation | undefined>;
  errors: Record<string, string | undefined>;
  load(providerID: string): Promise<void>;
  start(providerID: string, authMethodID: string): Promise<void>;
  cancel(providerID: string, flowID: string): Promise<void>;
};

const generations = new Map<string, number>();
const pollTimers = new Map<string, ReturnType<typeof setTimeout>>();
const pollFailures = new Map<string, number>();
const refreshedSuccessFlows = new Set<string>();

function isActive(snapshot: ProviderExternalAuthFlowSnapshot | undefined): boolean {
  return snapshot?.state === 'launching'
    || snapshot?.state === 'awaiting_user'
    || snapshot?.state === 'verifying';
}

function activeFlowBinding(
  snapshot: ProviderExternalAuthFlowSnapshot | undefined
): ActiveFlowBinding | undefined {
  if (!isActive(snapshot) || !snapshot?.flowId) return undefined;
  return {
    providerId: snapshot.providerId,
    authMethodId: snapshot.authMethodId,
    flowId: snapshot.flowId
  };
}

function matchesFlow(
  snapshot: ProviderExternalAuthFlowSnapshot,
  binding: ActiveFlowBinding
): boolean {
  return snapshot.providerId === binding.providerId
    && snapshot.authMethodId === binding.authMethodId
    && snapshot.flowId === binding.flowId;
}

function clearPoll(providerID: string): void {
  const timer = pollTimers.get(providerID);
  if (timer) clearTimeout(timer);
  pollTimers.delete(providerID);
}

function nextGeneration(providerID: string): number {
  const generation = (generations.get(providerID) ?? 0) + 1;
  generations.set(providerID, generation);
  pollFailures.delete(providerID);
  clearPoll(providerID);
  return generation;
}

function isCurrent(providerID: string, generation: number): boolean {
  return generations.get(providerID) === generation;
}

function genericError(operation: 'load' | 'start' | 'cancel'): string {
  switch (operation) {
    case 'start':
      return 'Could not start provider sign-in.';
    case 'cancel':
      return 'Could not cancel provider sign-in.';
    default:
      return 'Could not check provider sign-in status.';
  }
}

async function refreshProviderData(snapshot: ProviderExternalAuthFlowSnapshot): Promise<void> {
  const flowKey = snapshot.flowId ?? `${snapshot.providerId}:${snapshot.authMethodId}`;
  if (refreshedSuccessFlows.has(flowKey)) return;
  refreshedSuccessFlows.add(flowKey);
  await Promise.allSettled([
    useProvidersStore.getState().load(),
    useSystemStore.getState().loadConfig()
  ]);
}

function schedulePoll(
  providerID: string,
  generation: number,
  binding: ActiveFlowBinding
): void {
  clearPoll(providerID);
  if (!isCurrent(providerID, generation)) return;
  const failures = pollFailures.get(providerID) ?? 0;
  const delay = Math.min(MAX_POLL_DELAY_MS, BASE_POLL_DELAY_MS * 2 ** Math.min(failures, 3));
  pollTimers.set(
    providerID,
    setTimeout(() => void pollStatus(providerID, generation, binding), delay)
  );
}

function retryPoll(
  providerID: string,
  generation: number,
  binding: ActiveFlowBinding
): void {
  if (!isCurrent(providerID, generation)) return;
  pollFailures.set(providerID, (pollFailures.get(providerID) ?? 0) + 1);
  useProviderExternalAuthStore.setState((state) => ({
    errors: {
      ...state.errors,
      [providerID]: 'Provider sign-in status check failed; retrying.'
    }
  }));
  schedulePoll(providerID, generation, binding);
}

async function applySnapshot(
  providerID: string,
  generation: number,
  snapshot: ProviderExternalAuthFlowSnapshot
): Promise<void> {
  if (!isCurrent(providerID, generation)) return;
  pollFailures.delete(providerID);
  useProviderExternalAuthStore.setState((state) => ({
    snapshots: { ...state.snapshots, [providerID]: snapshot },
    busy: { ...state.busy, [providerID]: undefined },
    errors: { ...state.errors, [providerID]: undefined }
  }));
  const binding = activeFlowBinding(snapshot);
  if (binding) {
    schedulePoll(providerID, generation, binding);
  } else {
    clearPoll(providerID);
  }
  if (snapshot.state === 'succeeded') {
    await refreshProviderData(snapshot);
  }
}

async function pollStatus(
  providerID: string,
  generation: number,
  binding: ActiveFlowBinding
): Promise<void> {
  if (!isCurrent(providerID, generation)) return;
  const bridge = useShellStore.getState().bridge;
  if (!bridge?.providerExternalAuthStatus) {
    clearPoll(providerID);
    useProviderExternalAuthStore.setState((state) => ({
      errors: { ...state.errors, [providerID]: 'Provider sign-in is unavailable in this build.' }
    }));
    return;
  }
  try {
    const snapshot = await bridge.providerExternalAuthStatus(binding);
    if (!isCurrent(providerID, generation)) return;
    if (!matchesFlow(snapshot, binding)) {
      retryPoll(providerID, generation, binding);
      return;
    }
    await applySnapshot(providerID, generation, snapshot);
  } catch {
    retryPoll(providerID, generation, binding);
  }
}

export const useProviderExternalAuthStore = create<ProviderExternalAuthState>()((set, get) => ({
  snapshots: {},
  busy: {},
  errors: {},

  async load(providerID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const generation = nextGeneration(providerID);
    if (fixtureMode) {
      set((state) => ({
        busy: { ...state.busy, [providerID]: undefined },
        errors: { ...state.errors, [providerID]: undefined }
      }));
      return;
    }
    if (!bridge?.providerExternalAuthStatus) {
      set((state) => ({
        busy: { ...state.busy, [providerID]: undefined },
        errors: { ...state.errors, [providerID]: 'Provider sign-in is unavailable in this build.' }
      }));
      return;
    }
    set((state) => ({
      busy: { ...state.busy, [providerID]: 'loading' },
      errors: { ...state.errors, [providerID]: undefined }
    }));
    try {
      const snapshot = await bridge.providerExternalAuthStatus({ providerId: providerID });
      await applySnapshot(providerID, generation, snapshot);
    } catch {
      if (!isCurrent(providerID, generation)) return;
      set((state) => ({
        busy: { ...state.busy, [providerID]: undefined },
        errors: { ...state.errors, [providerID]: genericError('load') }
      }));
      const binding = activeFlowBinding(get().snapshots[providerID]);
      if (binding) {
        schedulePoll(providerID, generation, binding);
      }
    }
  },

  async start(providerID, authMethodID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode || get().busy[providerID] || !bridge?.providerExternalAuthStart) return;
    if (Object.values(get().snapshots).some(isActive)) return;
    const generation = nextGeneration(providerID);
    set((state) => ({
      busy: { ...state.busy, [providerID]: 'starting' },
      errors: { ...state.errors, [providerID]: undefined }
    }));
    try {
      const snapshot = await bridge.providerExternalAuthStart({
        providerId: providerID,
        authMethodId: authMethodID
      });
      await applySnapshot(providerID, generation, snapshot);
    } catch {
      if (!isCurrent(providerID, generation)) return;
      set((state) => ({
        busy: { ...state.busy, [providerID]: undefined },
        errors: { ...state.errors, [providerID]: genericError('start') }
      }));
    }
  },

  async cancel(providerID, flowID) {
    const bridge = useShellStore.getState().bridge;
    if (get().busy[providerID] === 'cancelling' || !bridge?.providerExternalAuthCancel) return;
    const generation = nextGeneration(providerID);
    set((state) => ({
      busy: { ...state.busy, [providerID]: 'cancelling' },
      errors: { ...state.errors, [providerID]: undefined }
    }));
    try {
      const snapshot = await bridge.providerExternalAuthCancel(flowID);
      await applySnapshot(providerID, generation, snapshot);
    } catch {
      if (!isCurrent(providerID, generation)) return;
      set((state) => ({
        busy: { ...state.busy, [providerID]: undefined },
        errors: { ...state.errors, [providerID]: genericError('cancel') }
      }));
      const binding = activeFlowBinding(get().snapshots[providerID]);
      if (binding) {
        schedulePoll(providerID, generation, binding);
      }
    }
  }
}));

export function resetProviderExternalAuthStoreForTests(): void {
  for (const providerID of pollTimers.keys()) clearPoll(providerID);
  generations.clear();
  pollFailures.clear();
  refreshedSuccessFlows.clear();
  useProviderExternalAuthStore.setState({ snapshots: {}, busy: {}, errors: {} });
}
