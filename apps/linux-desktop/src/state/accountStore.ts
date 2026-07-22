import { create } from 'zustand';
import { fixtureAccountStatus } from '../daemonFixture.js';
import type { AccountStatus } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type AccountState = {
  data: AccountStatus | null;
  loading: boolean;
  busyAction: 'sign-in' | 'cancel' | 'rotate-identity' | 'sign-out' | null;
  error: string | null;
  load(): Promise<void>;
  beginSignIn(): Promise<void>;
  cancelSignIn(): Promise<void>;
  rotateIdentity(): Promise<void>;
  signOut(): Promise<void>;
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Request failed';
}

export function isAmbiguousIdentityRotationError(error: unknown): boolean {
  const message = errorMessage(error).toLowerCase();
  return [
    'timed out',
    'timeout',
    'resource temporarily unavailable',
    'connection reset',
    'broken pipe',
    'unexpected eof',
    'eof while parsing',
    'rpc response missing result'
  ].some((marker) => message.includes(marker));
}

export const useAccountStore = create<AccountState>()((set, get) => {
  let requestGeneration = 0;
  let loadInFlight: Promise<void> | null = null;

  function beginMutation(action: NonNullable<AccountState['busyAction']>): boolean {
    if (get().busyAction !== null) return false;
    requestGeneration += 1;
    set({ busyAction: action, loading: false, error: null });
    return true;
  }

  return {
    data: null,
    loading: false,
    busyAction: null,
    error: null,
    async load() {
      if (get().busyAction !== null) return;
      if (loadInFlight) return loadInFlight;

      const generation = requestGeneration;
      const request = (async () => {
        const { fixtureMode, bridge } = useShellStore.getState();
        if (fixtureMode) {
          if (generation === requestGeneration) {
            set({ data: fixtureAccountStatus(), loading: false, error: null });
          }
          return;
        }
        if (!bridge) {
          if (generation === requestGeneration) {
            set({ loading: false, error: 'Packaged shell required for live data.' });
          }
          return;
        }
        set({ loading: true, error: null });
        try {
          const data = await bridge.accountStatus();
          if (generation === requestGeneration) {
            set({ data, loading: false, error: null });
          }
        } catch (error) {
          if (generation === requestGeneration) {
            set({ loading: false, error: errorMessage(error) });
          }
        }
      })();

      loadInFlight = request;
      try {
        await request;
      } finally {
        if (loadInFlight === request) loadInFlight = null;
      }
    },
    async beginSignIn() {
      const { fixtureMode, bridge } = useShellStore.getState();
      if (fixtureMode || !bridge) {
        set({ error: fixtureMode ? 'Sign-in is unavailable in fixture mode.' : 'Packaged shell required for sign-in.' });
        return;
      }
      if (!beginMutation('sign-in')) return;
      try {
        const operation = await bridge.accountBeginSignIn();
        set({
          data: {
            state: 'authorizing',
            signedIn: false,
            trustClass: 'linux-lower-trust',
            syncState: 'local-only',
            authorizationOperationID: operation.operationID,
            authorizationExpiresAt: operation.expiresAt,
            deviceApprovalRequired: false
          },
          busyAction: null,
          error: null
        });
      } catch (error) {
        set({ busyAction: null, error: errorMessage(error) });
      }
    },
    async cancelSignIn() {
      const { fixtureMode, bridge } = useShellStore.getState();
      const operationID = get().data?.authorizationOperationID;
      if (fixtureMode) {
        set({ error: 'Sign-in cancellation is unavailable in fixture mode.' });
        return;
      }
      if (!bridge || !operationID) {
        set({ error: 'No active sign-in operation is available to cancel.' });
        return;
      }
      if (!beginMutation('cancel')) return;
      try {
        const data = await bridge.accountCancelSignIn(operationID);
        set({ data, busyAction: null, error: null });
      } catch (error) {
        set({ busyAction: null, error: errorMessage(error) });
      }
    },
    async rotateIdentity() {
      const { fixtureMode, bridge } = useShellStore.getState();
      if (fixtureMode) {
        set({ error: 'Installation identity rotation is unavailable in fixture mode.' });
        return;
      }
      if (!bridge) {
        set({ error: 'Packaged shell required to rotate the Linux installation identity.' });
        return;
      }
      if (!beginMutation('rotate-identity')) return;
      try {
        const data = await bridge.accountRotateIdentity();
        set({ data, busyAction: null, error: null });
      } catch (error) {
        const mutationError = errorMessage(error);
        if (!isAmbiguousIdentityRotationError(error)) {
          set({ busyAction: null, error: mutationError });
          return;
        }
        try {
          // A socket timeout is ambiguous: the daemon may finish rotation after
          // the renderer stops waiting. Re-read daemon authority before
          // presenting the old rejected key as current.
          const data = await bridge.accountStatus();
          set({
            data,
            busyAction: null,
            error: data.detail === 'device_rejected' ? mutationError : null
          });
        } catch {
          set({ busyAction: null, error: mutationError });
        }
      }
    },
    async signOut() {
      const { fixtureMode, bridge } = useShellStore.getState();
      if (fixtureMode) {
        set({ error: 'Sign-out is unavailable in fixture mode.' });
        return;
      }
      if (!bridge) {
        set({ error: 'Packaged shell required for sign-out.' });
        return;
      }
      if (!beginMutation('sign-out')) return;
      try {
        const data = await bridge.accountSignOut();
        set({ data, busyAction: null, error: null });
      } catch (error) {
        set({ busyAction: null, error: errorMessage(error) });
      }
    }
  };
});
