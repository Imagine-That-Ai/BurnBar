import { create } from 'zustand';
import { fixtureAccountStatus } from '../daemonFixture.js';
import type { AccountDeviceAuthSession, AccountStatus, LinuxShellBridge } from '../tauriBridge.js';
import { resetMembershipForIdentityChange, useMembershipStore } from './membershipStore.js';
import { useShellStore } from './shellStore.js';

export type AccountAuthPhase =
  | 'idle'
  | 'starting'
  | 'pending'
  | 'cancelling'
  | 'cancelled'
  | 'expired'
  | 'signing-out'
  | 'error'
  | 'capability-absent';

export type AccountState = {
  data: AccountStatus | null;
  loading: boolean;
  error: string | null;
  authPhase: AccountAuthPhase;
  authSession: AccountDeviceAuthSession | null;
  authError: string | null;
  browserError: string | null;
  load(): Promise<void>;
  startDeviceAuth(): Promise<void>;
  reopenDeviceAuth(): Promise<void>;
  cancelDeviceAuth(): Promise<void>;
  signOut(): Promise<void>;
  resetAuthAttempt(): void;
};

const MIN_POLL_SECONDS = 2;
const MAX_POLL_SECONDS = 30;
const MAX_RETRY_SECONDS = 30;
let authGeneration = 0;
let pollTimer: ReturnType<typeof setTimeout> | null = null;
let consecutivePollFailures = 0;

function isCapabilityAbsent(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? '');
  return /unknown|unsupported|unrecognized|not implemented|invalid method|method not found/i.test(message);
}

function isTerminalAuthError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? '');
  return /invalid[_ -]?flow|authorization flow is no longer active|reauthentication|required|unauthorized/i.test(
    message
  );
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : String(error || fallback);
}

function clearPollTimer(): void {
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = null;
}

function invalidateAuthAttempt(): number {
  authGeneration += 1;
  consecutivePollFailures = 0;
  clearPollTimer();
  return authGeneration;
}

function boundedPollDelay(session: AccountDeviceAuthSession, failureCount = 0): number {
  const baseSeconds = Math.min(MAX_POLL_SECONDS, Math.max(MIN_POLL_SECONDS, session.pollIntervalSeconds));
  const retrySeconds = Math.min(MAX_RETRY_SECONDS, baseSeconds * 2 ** Math.min(failureCount, 3));
  return retrySeconds * 1_000;
}

function sessionExpired(session: AccountDeviceAuthSession): boolean {
  return Date.parse(session.expiresAt) <= Date.now();
}

function activeBridge(): LinuxShellBridge | null {
  return useShellStore.getState().bridge;
}

async function refreshMembership(clearCache = false): Promise<void> {
  if (clearCache) resetMembershipForIdentityChange();
  await useMembershipStore.getState().load();
}

function schedulePoll(session: AccountDeviceAuthSession, generation: number, delayMs?: number): void {
  clearPollTimer();
  if (generation !== authGeneration) return;
  if (sessionExpired(session)) {
    useAccountStore.setState({
      authPhase: 'expired',
      authError: 'This sign-in code expired. Start a new browser sign-in.',
      browserError: null
    });
    return;
  }
  const untilExpiry = Math.max(0, Date.parse(session.expiresAt) - Date.now());
  pollTimer = setTimeout(
    () => void pollDeviceAuth(session.flowId, generation),
    Math.min(delayMs ?? boundedPollDelay(session), untilExpiry)
  );
}

async function pollDeviceAuth(flowId: string, generation: number): Promise<void> {
  if (generation !== authGeneration) return;
  const bridge = activeBridge();
  if (!bridge?.accountDeviceAuthPoll) {
    useAccountStore.setState({
      authPhase: 'capability-absent',
      authError: 'This daemon build does not expose Linux browser sign-in.'
    });
    return;
  }
  const currentSession = useAccountStore.getState().authSession;
  if (!currentSession || currentSession.flowId !== flowId) return;
  if (sessionExpired(currentSession)) {
    schedulePoll(currentSession, generation, 0);
    return;
  }
  try {
    const data = await bridge.accountDeviceAuthPoll(flowId);
    if (generation !== authGeneration) return;
    consecutivePollFailures = 0;
    if (data.state === 'signed_in') {
      clearPollTimer();
      useAccountStore.setState({
        data,
        authPhase: 'idle',
        authSession: null,
        authError: null,
        browserError: null,
        error: null
      });
      await refreshMembership(true);
      return;
    }
    if (data.state === 'authorization_pending' && data.session) {
      useAccountStore.setState({
        data,
        authPhase: 'pending',
        authSession: data.session,
        authError: data.problem?.message ?? null,
        error: null
      });
      schedulePoll(data.session, generation);
      return;
    }
    clearPollTimer();
    const expired = data.problem?.code === 'authorization_expired';
    useAccountStore.setState({
      data,
      authPhase: expired ? 'expired' : 'error',
      authSession: null,
      authError: data.problem?.message ?? 'Browser sign-in ended before authorization completed.',
      browserError: null
    });
  } catch (error) {
    if (generation !== authGeneration) return;
    if (isCapabilityAbsent(error)) {
      clearPollTimer();
      useAccountStore.setState({
        authPhase: 'capability-absent',
        authError: 'This daemon build does not expose Linux browser sign-in.'
      });
      return;
    }
    if (isTerminalAuthError(error)) {
      clearPollTimer();
      useAccountStore.setState({
        authPhase: 'error',
        authSession: null,
        authError: errorMessage(error, 'Browser sign-in is no longer active.')
      });
      return;
    }
    consecutivePollFailures += 1;
    useAccountStore.setState({
      authPhase: 'pending',
      authError: `Sign-in check failed; retrying: ${errorMessage(error, 'Request failed')}`
    });
    schedulePoll(currentSession, generation, boundedPollDelay(currentSession, consecutivePollFailures));
  }
}

export const useAccountStore = create<AccountState>()((set, get) => ({
  data: null,
  loading: false,
  error: null,
  authPhase: 'idle',
  authSession: null,
  authError: null,
  browserError: null,

  async load() {
    const activePhase = get().authPhase;
    if (
      activePhase === 'starting' ||
      activePhase === 'pending' ||
      activePhase === 'cancelling' ||
      activePhase === 'signing-out'
    ) {
      return;
    }
    const generation = authGeneration;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      invalidateAuthAttempt();
      set({
        data: fixtureAccountStatus(),
        loading: false,
        error: null,
        authPhase: 'idle'
      });
      return;
    }
    if (!bridge) {
      set({ loading: false, error: 'Packaged shell required for live data.' });
      return;
    }
    set({ loading: true, error: null });
    try {
      const data = await bridge.accountStatus();
      if (generation !== authGeneration) return;
      if (data.state === 'authorization_pending' && data.session) {
        const generation = invalidateAuthAttempt();
        set({
          data,
          loading: false,
          error: null,
          authPhase: 'pending',
          authSession: data.session,
          authError: data.problem?.message ?? null
        });
        schedulePoll(data.session, generation);
        return;
      }
      invalidateAuthAttempt();
      const expired = data.problem?.code === 'authorization_expired';
      set({
        data,
        loading: false,
        error: null,
        authPhase: expired ? 'expired' : data.problem ? 'error' : 'idle',
        authSession: null,
        authError: data.problem?.message ?? null,
        browserError: null
      });
    } catch (error) {
      if (generation !== authGeneration) return;
      set({
        loading: false,
        error: isCapabilityAbsent(error)
          ? 'This daemon build does not expose Linux account RPC yet.'
          : errorMessage(error, 'Account request failed')
      });
    }
  },

  async startDeviceAuth() {
    const { fixtureMode, bridge } = useShellStore.getState();
    const activePhase = get().authPhase;
    if (
      fixtureMode ||
      activePhase === 'starting' ||
      activePhase === 'pending' ||
      activePhase === 'cancelling' ||
      activePhase === 'signing-out'
    ) {
      return;
    }
    const generation = invalidateAuthAttempt();
    if (!bridge?.accountDeviceAuthStart || !bridge.openAccountAuthUrl) {
      set({
        loading: false,
        authPhase: 'capability-absent',
        authError: 'This daemon build does not expose Linux browser sign-in.'
      });
      return;
    }
    set({
      loading: false,
      authPhase: 'starting',
      authSession: null,
      authError: null,
      browserError: null
    });
    try {
      const data = await bridge.accountDeviceAuthStart();
      if (generation !== authGeneration) return;
      if (data.state !== 'authorization_pending' || !data.session) {
        set({
          data,
          authPhase: data.state === 'signed_in' ? 'idle' : 'error',
          authError:
            data.problem?.message ?? (data.state === 'signed_in' ? null : 'Daemon did not start browser sign-in.')
        });
        if (data.state === 'signed_in') await refreshMembership();
        return;
      }
      set({
        data,
        authPhase: 'pending',
        authSession: data.session,
        authError: data.problem?.message ?? null,
        browserError: null,
        error: null
      });
      schedulePoll(data.session, generation);
      try {
        await bridge.openAccountAuthUrl(data.session.verificationUrl);
      } catch (error) {
        if (generation === authGeneration) {
          set({
            browserError: `Could not open the browser: ${errorMessage(error, 'Open failed')}`
          });
        }
      }
    } catch (error) {
      if (generation !== authGeneration) return;
      set({
        authPhase: isCapabilityAbsent(error) ? 'capability-absent' : 'error',
        authError: isCapabilityAbsent(error)
          ? 'This daemon build does not expose Linux browser sign-in.'
          : errorMessage(error, 'Could not start browser sign-in')
      });
    }
  },

  async reopenDeviceAuth() {
    const bridge = activeBridge();
    const session = get().authSession;
    if (!bridge?.openAccountAuthUrl || !session) return;
    const generation = authGeneration;
    try {
      await bridge.openAccountAuthUrl(session.verificationUrl);
      if (generation !== authGeneration || get().authSession?.flowId !== session.flowId) return;
      set({ browserError: null });
    } catch (error) {
      if (generation !== authGeneration || get().authSession?.flowId !== session.flowId) return;
      set({
        browserError: `Could not open the browser: ${errorMessage(error, 'Open failed')}`
      });
    }
  },

  async cancelDeviceAuth() {
    const bridge = activeBridge();
    const session = get().authSession;
    if (get().authPhase === 'cancelling') return;
    const generation = invalidateAuthAttempt();
    if (!session) {
      set({
        loading: false,
        authPhase: 'cancelled',
        authSession: null,
        authError: null,
        browserError: null
      });
      return;
    }
    set({
      loading: false,
      authPhase: 'cancelling',
      authError: null,
      browserError: null
    });
    if (!bridge?.accountDeviceAuthCancel) {
      set({
        authPhase: 'capability-absent',
        authError: 'This daemon build cannot cancel Linux browser sign-in.'
      });
      return;
    }
    try {
      const data = await bridge.accountDeviceAuthCancel(session.flowId);
      if (generation !== authGeneration) return;
      set({
        data,
        authPhase: 'cancelled',
        authSession: null,
        authError: null,
        browserError: null
      });
    } catch (error) {
      if (generation !== authGeneration) return;
      set({
        authPhase: 'error',
        authError: errorMessage(error, 'Could not cancel browser sign-in')
      });
    }
  },

  async signOut() {
    const bridge = activeBridge();
    if (get().authPhase === 'signing-out') return;
    const generation = invalidateAuthAttempt();
    if (!bridge?.accountSignOut) {
      set({
        authPhase: 'capability-absent',
        authError: 'This daemon build does not expose Linux sign-out.'
      });
      return;
    }
    resetMembershipForIdentityChange();
    set({
      loading: false,
      authPhase: 'signing-out',
      authError: null,
      browserError: null
    });
    try {
      const data = await bridge.accountSignOut();
      if (generation !== authGeneration) return;
      set({
        data,
        authPhase: 'idle',
        authSession: null,
        authError: data.problem?.message ?? null,
        error: null
      });
      await refreshMembership();
    } catch (error) {
      if (generation !== authGeneration) return;
      set({
        authPhase: 'error',
        authError: errorMessage(error, 'Could not sign out')
      });
      await refreshMembership();
    }
  },

  resetAuthAttempt() {
    invalidateAuthAttempt();
    set({
      loading: false,
      authPhase: 'idle',
      authSession: null,
      authError: null,
      browserError: null
    });
  }
}));

export function resetAccountStoreForTests(): void {
  invalidateAuthAttempt();
  useAccountStore.setState({
    data: null,
    loading: false,
    error: null,
    authPhase: 'idle',
    authSession: null,
    authError: null,
    browserError: null
  });
}
