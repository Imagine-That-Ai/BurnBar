import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountStatus } from '../tauriBridge.js';
import { useAccountStore } from './accountStore.js';
import { useShellStore } from './shellStore.js';

const signedOut: AccountStatus = {
  state: 'signed-out',
  signedIn: false,
  trustClass: 'linux-lower-trust',
  syncState: 'local-only',
  deviceApprovalRequired: false
};

function deferred<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((continuation) => {
    resolve = continuation;
  });
  return { promise, resolve };
}

describe('accountStore daemon-owned auth actions', () => {
  beforeEach(() => {
    useAccountStore.setState({ data: null, loading: false, busyAction: null, error: null });
    useShellStore.setState({ fixtureMode: false, bridge: null });
  });

  it('keeps the browser authorization URL outside renderer state', async () => {
    const accountBeginSignIn = vi.fn(async () => ({
      operationID: 'op-1',
      expiresAt: '2026-07-11T22:00:00Z'
    }));
    useShellStore.setState({ bridge: { accountBeginSignIn } as never });

    await useAccountStore.getState().beginSignIn();

    expect(accountBeginSignIn).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toMatchObject({
      state: 'authorizing',
      authorizationOperationID: 'op-1'
    });
    expect(JSON.stringify(useAccountStore.getState())).not.toMatch(
      /authorizationURL|refreshToken|idToken|appCheckToken|deviceID|sessionGeneration/
    );
  });

  it('binds cancellation to the current daemon operation ID', async () => {
    const accountCancelSignIn = vi.fn(async (operationID: string) => {
      expect(operationID).toBe('op-current');
      return signedOut;
    });
    useShellStore.setState({ bridge: { accountCancelSignIn } as never });
    useAccountStore.setState({
      data: {
        ...signedOut,
        state: 'authorizing',
        authorizationOperationID: 'op-current'
      }
    });

    await useAccountStore.getState().cancelSignIn();

    expect(accountCancelSignIn).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toEqual(signedOut);
  });

  it('retains signed-in state when remote sign-out fails', async () => {
    const active: AccountStatus = {
      ...signedOut,
      state: 'active',
      signedIn: true,
      identityLabel: 'user@example.com',
      syncState: 'active'
    };
    useShellStore.setState({
      bridge: {
        accountSignOut: vi.fn(async () => {
          throw new Error('daemon refused sign-out');
        })
      } as never
    });
    useAccountStore.setState({ data: active });

    await useAccountStore.getState().signOut();

    expect(useAccountStore.getState().data).toEqual(active);
    expect(useAccountStore.getState().error).toMatch(/daemon refused sign-out/i);
  });

  it('rotates a rejected installation identity only through the daemon bridge', async () => {
    const awaitingApproval: AccountStatus = {
      ...signedOut,
      state: 'awaiting-device-approval',
      deviceApprovalRequired: true
    };
    const accountRotateIdentity = vi.fn(async () => awaitingApproval);
    useShellStore.setState({ bridge: { accountRotateIdentity } as never });
    useAccountStore.setState({
      data: { ...signedOut, state: 'unavailable', detail: 'device_rejected' }
    });

    await useAccountStore.getState().rotateIdentity();

    expect(accountRotateIdentity).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toEqual(awaitingApproval);
    expect(useAccountStore.getState().busyAction).toBeNull();
  });

  it('reconciles authoritative status after an ambiguous rotation timeout', async () => {
    const awaitingApproval: AccountStatus = {
      ...signedOut,
      state: 'awaiting-device-approval',
      deviceApprovalRequired: true
    };
    const accountRotateIdentity = vi.fn(async () => {
      throw new Error('Resource temporarily unavailable (os error 11)');
    });
    const accountStatus = vi.fn(async () => awaitingApproval);
    useShellStore.setState({ bridge: { accountRotateIdentity, accountStatus } as never });
    useAccountStore.setState({
      data: { ...signedOut, state: 'unavailable', detail: 'device_rejected' }
    });

    await useAccountStore.getState().rotateIdentity();

    expect(accountRotateIdentity).toHaveBeenCalledOnce();
    expect(accountStatus).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toEqual(awaitingApproval);
    expect(useAccountStore.getState().error).toBeNull();
    expect(useAccountStore.getState().busyAction).toBeNull();
  });

  it('keeps deterministic rotation failures visible and retryable without status reconciliation', async () => {
    const rejected: AccountStatus = {
      ...signedOut,
      state: 'unavailable',
      signedIn: true,
      detail: 'device_rejected'
    };
    const accountRotateIdentity = vi.fn(async () => {
      throw new Error('The Linux installation identity is unavailable or corrupt.');
    });
    const accountStatus = vi.fn(async () => signedOut);
    useShellStore.setState({ bridge: { accountRotateIdentity, accountStatus } as never });
    useAccountStore.setState({ data: rejected });

    await useAccountStore.getState().rotateIdentity();

    expect(accountRotateIdentity).toHaveBeenCalledOnce();
    expect(accountStatus).not.toHaveBeenCalled();
    expect(useAccountStore.getState().data).toEqual(rejected);
    expect(useAccountStore.getState().error).toMatch(/identity is unavailable or corrupt/i);
    expect(useAccountStore.getState().busyAction).toBeNull();
  });

  it('preserves the current authorization operation across a transient poll failure', async () => {
    const authorizing: AccountStatus = {
      ...signedOut,
      state: 'authorizing',
      authorizationOperationID: 'op-current'
    };
    useShellStore.setState({
      bridge: {
        accountStatus: vi.fn(async () => {
          throw new Error('temporary daemon timeout');
        })
      } as never
    });
    useAccountStore.setState({ data: authorizing });

    await useAccountStore.getState().load();

    expect(useAccountStore.getState().data).toEqual(authorizing);
    expect(useAccountStore.getState().error).toMatch(/temporary daemon timeout/i);
  });

  it('does not let a stale poll overwrite a completed cancellation', async () => {
    const poll = deferred<AccountStatus>();
    const authorizing: AccountStatus = {
      ...signedOut,
      state: 'authorizing',
      authorizationOperationID: 'op-current'
    };
    const accountStatus = vi.fn(() => poll.promise);
    const accountCancelSignIn = vi.fn(async () => signedOut);
    useShellStore.setState({ bridge: { accountStatus, accountCancelSignIn } as never });
    useAccountStore.setState({ data: authorizing });

    const staleLoad = useAccountStore.getState().load();
    await useAccountStore.getState().cancelSignIn();
    poll.resolve({ ...authorizing, state: 'awaiting-device-approval' });
    await staleLoad;

    expect(accountStatus).toHaveBeenCalledOnce();
    expect(accountCancelSignIn).toHaveBeenCalledWith('op-current');
    expect(useAccountStore.getState().data).toEqual(signedOut);
    expect(useAccountStore.getState().loading).toBe(false);
  });

  it('restarts status loading for a replacement shell and ignores the stale identity', async () => {
    const oldPoll = deferred<AccountStatus>();
    const newPoll = deferred<AccountStatus>();
    const oldIdentity: AccountStatus = {
      ...signedOut,
      state: 'active',
      signedIn: true,
      identityLabel: 'old@example.com',
      syncState: 'active'
    };
    const newIdentity: AccountStatus = {
      ...signedOut,
      state: 'active',
      signedIn: true,
      identityLabel: 'new@example.com',
      syncState: 'active'
    };
    const oldBridge = { accountStatus: vi.fn(() => oldPoll.promise) };
    const newBridge = { accountStatus: vi.fn(() => newPoll.promise) };
    useShellStore.setState({ bridge: oldBridge as never });

    const oldLoad = useAccountStore.getState().load();
    await Promise.resolve();
    useShellStore.setState({ bridge: newBridge as never });
    const newLoad = useAccountStore.getState().load();
    await Promise.resolve();

    oldPoll.resolve(oldIdentity);
    await Promise.resolve();
    expect(useAccountStore.getState().data).not.toMatchObject({ identityLabel: 'old@example.com' });

    newPoll.resolve(newIdentity);
    await Promise.all([oldLoad, newLoad]);

    expect(oldBridge.accountStatus).toHaveBeenCalledOnce();
    expect(newBridge.accountStatus).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toMatchObject({ identityLabel: 'new@example.com' });
    expect(useAccountStore.getState().loading).toBe(false);
  });

  it('does not let a completed sign-out overwrite a newer account sign-in', async () => {
    const signOut = deferred<AccountStatus>();
    const beginSignIn = deferred<{ operationID: string; expiresAt: string }>();
    const oldBridge = { accountSignOut: vi.fn(() => signOut.promise) };
    const newBridge = { accountBeginSignIn: vi.fn(() => beginSignIn.promise) };
    const active: AccountStatus = {
      ...signedOut,
      state: 'active',
      signedIn: true,
      identityLabel: 'old@example.com',
      syncState: 'active'
    };
    useAccountStore.setState({ data: active });
    useShellStore.setState({ bridge: oldBridge as never });

    const signOutRequest = useAccountStore.getState().signOut();
    await Promise.resolve();
    useShellStore.setState({ bridge: newBridge as never });
    const signInRequest = useAccountStore.getState().beginSignIn();
    await Promise.resolve();

    signOut.resolve(signedOut);
    await signOutRequest;

    // The late old-account response must not clear the new mutation's busy
    // state or make the renderer look signed out before the new operation
    // returns its own authoritative phase.
    expect(useAccountStore.getState().busyAction).toBe('sign-in');
    beginSignIn.resolve({ operationID: 'new-op', expiresAt: '2026-07-11T22:00:00Z' });
    await signInRequest;

    expect(oldBridge.accountSignOut).toHaveBeenCalledOnce();
    expect(newBridge.accountBeginSignIn).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toMatchObject({
      state: 'authorizing',
      authorizationOperationID: 'new-op'
    });
    expect(useAccountStore.getState().busyAction).toBeNull();
  });

  it('coalesces overlapping status polls', async () => {
    const poll = deferred<AccountStatus>();
    const accountStatus = vi.fn(() => poll.promise);
    useShellStore.setState({ bridge: { accountStatus } as never });

    const first = useAccountStore.getState().load();
    const second = useAccountStore.getState().load();
    poll.resolve(signedOut);
    await Promise.all([first, second]);

    expect(accountStatus).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data).toEqual(signedOut);
  });

  it('serializes account mutations', async () => {
    const signIn = deferred<{ operationID: string; expiresAt: string }>();
    const accountBeginSignIn = vi.fn(() => signIn.promise);
    useShellStore.setState({ bridge: { accountBeginSignIn } as never });

    const first = useAccountStore.getState().beginSignIn();
    const duplicate = useAccountStore.getState().beginSignIn();
    signIn.resolve({ operationID: 'op-1', expiresAt: '2026-07-11T22:00:00Z' });
    await Promise.all([first, duplicate]);

    expect(accountBeginSignIn).toHaveBeenCalledOnce();
    expect(useAccountStore.getState().data?.authorizationOperationID).toBe('op-1');
  });

  it('does not dispatch auth mutations from fixture mode', async () => {
    const accountSignOut = vi.fn(async () => signedOut);
    const accountRotateIdentity = vi.fn(async () => signedOut);
    const accountCancelSignIn = vi.fn(async () => signedOut);
    useShellStore.setState({
      fixtureMode: true,
      bridge: { accountSignOut, accountRotateIdentity, accountCancelSignIn } as never
    });
    useAccountStore.setState({
      data: { ...signedOut, state: 'authorizing', authorizationOperationID: 'fixture-op' }
    });

    await useAccountStore.getState().cancelSignIn();
    await useAccountStore.getState().rotateIdentity();
    await useAccountStore.getState().signOut();

    expect(accountCancelSignIn).not.toHaveBeenCalled();
    expect(accountRotateIdentity).not.toHaveBeenCalled();
    expect(accountSignOut).not.toHaveBeenCalled();
    expect(useAccountStore.getState().error).toMatch(/fixture mode/i);
  });
});
