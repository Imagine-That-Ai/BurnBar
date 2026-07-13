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
  let loadInFlightContext: { fixtureMode: boolean; bridge: unknown } | null = null;
  let activeMutationContext: { fixtureMode: boolean; bridge: unknown } | null = null;

  function currentShellContext(): { fixtureMode: boolean; bridge: unknown } {
    const { fixtureMode, bridge } = useShellStore.getState();
    return { fixtureMode, bridge };
  }

  function sameShellContext(
    left: { fixtureMode: boolean; bridge: unknown },
    right: { fixtureMode: boolean; bridge: unknown }
  ): boolean {
    return left.fixtureMode === right.fixtureMode && left.bridge === right.bridge;
  }

  function mutationStillCurrent(generation: number, bridge: unknown): boolean {
    return generation === requestGeneration && sameShellContext(currentShellContext(), { fixtureMode: false, bridge });
  }

  function clearMutationContext(generation: number): void {
    if (generation === requestGeneration) activeMutationContext = null;
  }

  function beginMutation(action: NonNullable<AccountState['busyAction']>): boolean {
    const context = currentShellContext();
    if (activeMutationContext && !sameShellContext(activeMutationContext, context)) {
      // A shell replacement is an account-context boundary. Drop the old
      // identity before accepting a mutation from the new bridge; a late
      // response from the old daemon must never win the race.
      requestGeneration += 1;
      activeMutationContext = null;
      set({ data: null, loading: false, busyAction: null, error: 'Account context changed; checking the new account.' });
    }
    if (get().busyAction !== null) return false;
    requestGeneration += 1;
    activeMutationContext = context;
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
      const context = currentShellContext();
      if (loadInFlight && loadInFlightContext && sameShellContext(loadInFlightContext, context)) return loadInFlight;

      const generation = requestGeneration;
      const request = (async () => {
        if (context.fixtureMode) {
          if (generation === requestGeneration && sameShellContext(currentShellContext(), context)) {
            set({ data: fixtureAccountStatus(), loading: false, error: null });
          }
          return;
        }
        const bridge = context.bridge;
        if (!bridge || typeof bridge !== 'object') {
          if (generation === requestGeneration && sameShellContext(currentShellContext(), context)) {
            set({ loading: false, error: 'Packaged shell required for live data.' });
          }
          return;
        }
        if (generation === requestGeneration && sameShellContext(currentShellContext(), context)) {
          set({ loading: true, error: null });
        }
        try {
          const data = await (bridge as { accountStatus(): Promise<AccountStatus> }).accountStatus();
          if (generation === requestGeneration && sameShellContext(currentShellContext(), context)) {
            set({ data, loading: false, error: null });
          }
        } catch (error) {
          if (generation === requestGeneration && sameShellContext(currentShellContext(), context)) {
            set({ loading: false, error: errorMessage(error) });
          }
        }
      })();

      loadInFlight = request;
      loadInFlightContext = context;
      try {
        await request;
      } finally {
        if (loadInFlight === request) {
          loadInFlight = null;
          loadInFlightContext = null;
          // A bridge replacement invalidates the response, but must not leave
          // the old request's spinner stuck when no replacement load exists.
          if (generation === requestGeneration && !sameShellContext(currentShellContext(), context)) {
            set({ loading: false });
          }
        }
      }
    },
    async beginSignIn() {
      const { fixtureMode, bridge } = useShellStore.getState();
      if (fixtureMode || !bridge) {
        set({ error: fixtureMode ? 'Sign-in is unavailable in fixture mode.' : 'Packaged shell required for sign-in.' });
        return;
      }
      if (!beginMutation('sign-in')) return;
      const mutationGeneration = requestGeneration;
      try {
        const operation = await bridge.accountBeginSignIn();
        if (!mutationStillCurrent(mutationGeneration, bridge)) {
          if (mutationGeneration === requestGeneration) set({ busyAction: null });
          return;
        }
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
        if (mutationStillCurrent(mutationGeneration, bridge)) {
          set({ busyAction: null, error: errorMessage(error) });
        } else if (mutationGeneration === requestGeneration) {
          set({ busyAction: null });
        }
      } finally {
        clearMutationContext(mutationGeneration);
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
      const mutationGeneration = requestGeneration;
      try {
        const data = await bridge.accountCancelSignIn(operationID);
        if (mutationStillCurrent(mutationGeneration, bridge)) {
          set({ data, busyAction: null, error: null });
        } else if (mutationGeneration === requestGeneration) {
          set({ busyAction: null });
        }
      } catch (error) {
        if (mutationStillCurrent(mutationGeneration, bridge)) {
          set({ busyAction: null, error: errorMessage(error) });
        } else if (mutationGeneration === requestGeneration) {
          set({ busyAction: null });
        }
      } finally {
        clearMutationContext(mutationGeneration);
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
      const mutationGeneration = requestGeneration;
      try {
        const data = await bridge.accountRotateIdentity();
        if (mutationStillCurrent(mutationGeneration, bridge)) {
          set({ data, busyAction: null, error: null });
        } else if (mutationGeneration === requestGeneration) {
          set({ busyAction: null });
        }
      } catch (error) {
        const mutationError = errorMessage(error);
        if (!mutationStillCurrent(mutationGeneration, bridge)) {
          if (mutationGeneration === requestGeneration) set({ busyAction: null });
          return;
        }
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
      } finally {
        clearMutationContext(mutationGeneration);
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
      const mutationGeneration = requestGeneration;
      try {
        const data = await bridge.accountSignOut();
        if (mutationStillCurrent(mutationGeneration, bridge)) {
          set({ data, busyAction: null, error: null });
        } else if (mutationGeneration === requestGeneration) {
          set({ busyAction: null });
        }
      } catch (error) {
        if (mutationStillCurrent(mutationGeneration, bridge)) {
          set({ busyAction: null, error: errorMessage(error) });
        } else if (mutationGeneration === requestGeneration) {
          set({ busyAction: null });
        }
      } finally {
        clearMutationContext(mutationGeneration);
      }
    }
  };
});
