import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountStatus, LinuxShellBridge } from '../tauriBridge.js';
import { resetAccountStoreForTests, useAccountStore } from './accountStore.js';
import { useMembershipStore } from './membershipStore.js';
import { useShellStore } from './shellStore.js';

const NOW = new Date('2026-07-10T12:00:00Z');
const AUTH_URL = 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH';

function signedOut(problem?: AccountStatus['problem']): AccountStatus {
  return {
    state: 'signed_out',
    signedIn: false,
    trustClass: 'linux-lower-trust',
    syncState: 'local-only',
    problem,
    updatedAt: NOW.toISOString()
  };
}

function pending(expiresInMs = 60_000, flowId = 'flow-1'): AccountStatus {
  return {
    state: 'authorization_pending',
    signedIn: false,
    trustClass: 'linux-lower-trust',
    syncState: 'local-only',
    updatedAt: NOW.toISOString(),
    session: {
      flowId,
      userCode: 'ABCD-EFGH',
      verificationUrl: AUTH_URL,
      expiresAt: new Date(NOW.getTime() + expiresInMs).toISOString(),
      pollIntervalSeconds: 1
    }
  };
}

function signedIn(): AccountStatus {
  return {
    state: 'signed_in',
    signedIn: true,
    uid: 'user-1',
    email: 'user@example.com',
    identityLabel: 'user@example.com',
    trustClass: 'linux-lower-trust',
    syncState: 'active',
    credentialBackend: 'org.freedesktop.secrets',
    updatedAt: NOW.toISOString()
  };
}

function bridge(partial: Partial<LinuxShellBridge>): LinuxShellBridge {
  return {
    accountStatus: async () => signedOut(),
    ...partial
  } as LinuxShellBridge;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((next, fail) => {
    resolve = next;
    reject = fail;
  });
  return { promise, resolve, reject };
}

describe('accountStore device authentication', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    resetAccountStoreForTests();
    useMembershipStore.setState({ load: vi.fn(async () => {}) });
    useShellStore.setState({
      fixtureMode: false,
      bridge: null,
      bridgeReady: true
    });
  });

  afterEach(() => {
    resetAccountStoreForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('starts one browser flow and polls at the bounded interval until signed in', async () => {
    const start = vi.fn(async () => pending());
    const poll = vi.fn(async () => signedIn());
    const open = vi.fn(async () => {});
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: start,
        accountDeviceAuthPoll: poll,
        openAccountAuthUrl: open
      })
    });

    await useAccountStore.getState().startDeviceAuth();
    expect(start).toHaveBeenCalledTimes(1);
    expect(open).toHaveBeenCalledWith(AUTH_URL);
    expect(useAccountStore.getState().authPhase).toBe('pending');

    await vi.advanceTimersByTimeAsync(1_999);
    expect(poll).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(poll).toHaveBeenCalledWith('flow-1');
    expect(useAccountStore.getState().data?.state).toBe('signed_in');
    expect(useAccountStore.getState().authSession).toBeNull();
  });

  it('does not create a duplicate flow while start is pending', async () => {
    const result = deferred<AccountStatus>();
    const start = vi.fn(() => result.promise);
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: start,
        openAccountAuthUrl: async () => {}
      })
    });
    const first = useAccountStore.getState().startDeviceAuth();
    const second = useAccountStore.getState().startDeviceAuth();
    expect(start).toHaveBeenCalledTimes(1);
    result.resolve(pending());
    await Promise.all([first, second]);
  });

  it('lets browser sign-in supersede an in-flight account load without leaving loading stuck', async () => {
    const loadResult = deferred<AccountStatus>();
    useShellStore.setState({
      bridge: bridge({
        accountStatus: () => loadResult.promise,
        accountDeviceAuthStart: async () => pending(),
        openAccountAuthUrl: async () => {}
      })
    });

    const load = useAccountStore.getState().load();
    expect(useAccountStore.getState().loading).toBe(true);
    await useAccountStore.getState().startDeviceAuth();
    expect(useAccountStore.getState().loading).toBe(false);
    expect(useAccountStore.getState().authPhase).toBe('pending');
    expect(useAccountStore.getState().authSession?.userCode).toBe('ABCD-EFGH');

    loadResult.resolve(signedOut());
    await load;
    expect(useAccountStore.getState().loading).toBe(false);
    expect(useAccountStore.getState().authPhase).toBe('pending');
  });

  it('keeps polling when opening the browser fails and supports reopening', async () => {
    const open = vi.fn().mockRejectedValueOnce(new Error('no browser')).mockResolvedValueOnce(undefined);
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: async () => pending(),
        accountDeviceAuthPoll: async () => pending(),
        openAccountAuthUrl: open
      })
    });
    await useAccountStore.getState().startDeviceAuth();
    expect(useAccountStore.getState().authPhase).toBe('pending');
    expect(useAccountStore.getState().browserError).toContain('no browser');
    await useAccountStore.getState().reopenDeviceAuth();
    expect(open).toHaveBeenCalledTimes(2);
    expect(useAccountStore.getState().browserError).toBeNull();
  });

  it('expires locally without sending a late poll', async () => {
    const poll = vi.fn(async () => pending());
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: async () => pending(1_000),
        accountDeviceAuthPoll: poll,
        openAccountAuthUrl: async () => {}
      })
    });
    await useAccountStore.getState().startDeviceAuth();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(poll).not.toHaveBeenCalled();
    expect(useAccountStore.getState().authPhase).toBe('expired');
  });

  it('stops polling when the daemon reports a consumed or invalid flow', async () => {
    const poll = vi.fn(async () => {
      throw new Error('The account authorization flow is no longer active.');
    });
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: async () => pending(),
        accountDeviceAuthPoll: poll,
        openAccountAuthUrl: async () => {}
      })
    });
    await useAccountStore.getState().startDeviceAuth();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(useAccountStore.getState().authPhase).toBe('error');
    expect(useAccountStore.getState().authSession).toBeNull();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(poll).toHaveBeenCalledTimes(1);
  });

  it('invalidates an in-flight poll before cancellation so a late success cannot win', async () => {
    const pollResult = deferred<AccountStatus>();
    const cancel = vi.fn(async () => signedOut());
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: async () => pending(),
        accountDeviceAuthPoll: () => pollResult.promise,
        accountDeviceAuthCancel: cancel,
        openAccountAuthUrl: async () => {}
      })
    });
    await useAccountStore.getState().startDeviceAuth();
    await vi.advanceTimersByTimeAsync(2_000);
    const cancellation = useAccountStore.getState().cancelDeviceAuth();
    pollResult.resolve(signedIn());
    await cancellation;
    await Promise.resolve();
    expect(cancel).toHaveBeenCalledWith('flow-1');
    expect(useAccountStore.getState().data?.state).toBe('signed_out');
    expect(useAccountStore.getState().authPhase).toBe('cancelled');
  });

  it('blocks a new flow while cancellation is in flight', async () => {
    const cancelResult = deferred<AccountStatus>();
    const start = vi.fn(async () => pending());
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: start,
        accountDeviceAuthCancel: () => cancelResult.promise,
        openAccountAuthUrl: async () => {}
      })
    });

    await useAccountStore.getState().startDeviceAuth();
    const cancellation = useAccountStore.getState().cancelDeviceAuth();
    expect(useAccountStore.getState().authPhase).toBe('cancelling');
    await useAccountStore.getState().startDeviceAuth();
    expect(start).toHaveBeenCalledTimes(1);

    cancelResult.resolve(signedOut());
    await cancellation;
    expect(useAccountStore.getState().authPhase).toBe('cancelled');
  });

  it('ignores a late cancel completion after a newer flow starts', async () => {
    const cancelResult = deferred<AccountStatus>();
    const start = vi
      .fn<() => Promise<AccountStatus>>()
      .mockResolvedValueOnce(pending())
      .mockResolvedValueOnce(pending(60_000, 'flow-2'));
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: start,
        accountDeviceAuthCancel: () => cancelResult.promise,
        openAccountAuthUrl: async () => {}
      })
    });

    await useAccountStore.getState().startDeviceAuth();
    const cancellation = useAccountStore.getState().cancelDeviceAuth();
    useAccountStore.getState().resetAuthAttempt();
    await useAccountStore.getState().startDeviceAuth();
    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');

    cancelResult.resolve(signedOut());
    await cancellation;
    expect(useAccountStore.getState().authPhase).toBe('pending');
    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
    expect(useAccountStore.getState().data?.state).toBe('authorization_pending');
  });

  it('ignores a late cancel error after a newer flow starts', async () => {
    const cancelResult = deferred<AccountStatus>();
    const start = vi
      .fn<() => Promise<AccountStatus>>()
      .mockResolvedValueOnce(pending())
      .mockResolvedValueOnce(pending(60_000, 'flow-2'));
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: start,
        accountDeviceAuthCancel: () => cancelResult.promise,
        openAccountAuthUrl: async () => {}
      })
    });

    await useAccountStore.getState().startDeviceAuth();
    const cancellation = useAccountStore.getState().cancelDeviceAuth();
    useAccountStore.getState().resetAuthAttempt();
    await useAccountStore.getState().startDeviceAuth();
    cancelResult.reject(new Error('old cancel failed'));
    await cancellation;

    expect(useAccountStore.getState().authPhase).toBe('pending');
    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
    expect(useAccountStore.getState().authError).toBeNull();
  });

  it('does not let stale reopen completion clear a newer flow browser error', async () => {
    const oldReopen = deferred<void>();
    const open = vi
      .fn<(url: string) => Promise<void>>()
      .mockResolvedValueOnce(undefined)
      .mockImplementationOnce(() => oldReopen.promise)
      .mockRejectedValueOnce(new Error('flow-2 browser failed'));
    const start = vi
      .fn<() => Promise<AccountStatus>>()
      .mockResolvedValueOnce(pending())
      .mockResolvedValueOnce(pending(60_000, 'flow-2'));
    useShellStore.setState({ bridge: bridge({ accountDeviceAuthStart: start, openAccountAuthUrl: open }) });

    await useAccountStore.getState().startDeviceAuth();
    const reopen = useAccountStore.getState().reopenDeviceAuth();
    useAccountStore.getState().resetAuthAttempt();
    await useAccountStore.getState().startDeviceAuth();
    expect(useAccountStore.getState().browserError).toContain('flow-2 browser failed');
    oldReopen.resolve();
    await reopen;

    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
    expect(useAccountStore.getState().browserError).toContain('flow-2 browser failed');
  });

  it('does not let a stale reopen error affect a newer flow', async () => {
    const oldReopen = deferred<void>();
    const open = vi
      .fn<(url: string) => Promise<void>>()
      .mockResolvedValueOnce(undefined)
      .mockImplementationOnce(() => oldReopen.promise)
      .mockResolvedValueOnce(undefined);
    const start = vi
      .fn<() => Promise<AccountStatus>>()
      .mockResolvedValueOnce(pending())
      .mockResolvedValueOnce(pending(60_000, 'flow-2'));
    useShellStore.setState({ bridge: bridge({ accountDeviceAuthStart: start, openAccountAuthUrl: open }) });

    await useAccountStore.getState().startDeviceAuth();
    const reopen = useAccountStore.getState().reopenDeviceAuth();
    useAccountStore.getState().resetAuthAttempt();
    await useAccountStore.getState().startDeviceAuth();
    oldReopen.reject(new Error('old reopen failed'));
    await reopen;

    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
    expect(useAccountStore.getState().browserError).toBeNull();
  });

  it('does not let a manual status refresh invalidate an in-flight approval poll', async () => {
    const pollResult = deferred<AccountStatus>();
    const status = vi.fn(async () => pending());
    useShellStore.setState({
      bridge: bridge({
        accountStatus: status,
        accountDeviceAuthStart: async () => pending(),
        accountDeviceAuthPoll: () => pollResult.promise,
        openAccountAuthUrl: async () => {}
      })
    });
    await useAccountStore.getState().startDeviceAuth();
    await vi.advanceTimersByTimeAsync(2_000);

    await useAccountStore.getState().load();
    expect(status).not.toHaveBeenCalled();
    pollResult.resolve(signedIn());
    await Promise.resolve();
    await Promise.resolve();
    expect(useAccountStore.getState().data?.state).toBe('signed_in');
    expect(useAccountStore.getState().authPhase).toBe('idle');
  });

  it('maps older-daemon unknown methods to capability-absent', async () => {
    useShellStore.setState({
      bridge: bridge({
        accountDeviceAuthStart: async () => {
          throw new Error('unknown method daemon.account.device_auth.start');
        },
        openAccountAuthUrl: async () => {}
      })
    });
    await useAccountStore.getState().startDeviceAuth();
    expect(useAccountStore.getState().authPhase).toBe('capability-absent');
  });

  it('keeps current membership when the daemon has no sign-out capability', async () => {
    useMembershipStore.setState({
      data: {
        tier: 'pro',
        entitlements: ['burnbar_pro'],
        restoreAvailable: true
      }
    });
    useAccountStore.setState({ data: signedIn() });
    useShellStore.setState({ bridge: bridge({ accountSignOut: undefined }) });

    await useAccountStore.getState().signOut();

    expect(useAccountStore.getState().data?.state).toBe('signed_in');
    expect(useAccountStore.getState().authPhase).toBe('capability-absent');
    expect(useMembershipStore.getState().data?.tier).toBe('pro');
  });

  it('clears membership immediately on sign-out and refreshes after the daemon confirms it', async () => {
    const membershipLoad = vi.fn(async () => {});
    useMembershipStore.setState({
      data: {
        tier: 'pro',
        entitlements: ['burnbar_pro'],
        restoreAvailable: true
      },
      load: membershipLoad
    });
    useAccountStore.setState({ data: signedIn() });
    const signOutResult = deferred<AccountStatus>();
    const signOut = vi.fn(() => signOutResult.promise);
    useShellStore.setState({ bridge: bridge({ accountSignOut: signOut }) });

    const completion = useAccountStore.getState().signOut();
    expect(useMembershipStore.getState().data).toBeNull();
    signOutResult.resolve(signedOut());
    await completion;

    expect(signOut).toHaveBeenCalledTimes(1);
    expect(useAccountStore.getState().data?.state).toBe('signed_out');
    expect(membershipLoad).toHaveBeenCalledTimes(1);
  });

  it('restores membership when durable credential deletion rejects sign-out', async () => {
    const proMembership = {
      tier: 'pro' as const,
      entitlements: ['burnbar_pro'],
      restoreAvailable: true
    };
    const membershipLoad = vi.fn(async () => {
      useMembershipStore.setState({ data: proMembership, phase: 'idle', error: null });
    });
    useMembershipStore.setState({ data: proMembership, load: membershipLoad });
    useAccountStore.setState({ data: signedIn() });
    useShellStore.setState({
      bridge: bridge({
        accountSignOut: async () => Promise.reject(new Error('Secret Service is locked'))
      })
    });

    await useAccountStore.getState().signOut();

    expect(useAccountStore.getState().data?.state).toBe('signed_in');
    expect(useAccountStore.getState().authPhase).toBe('error');
    expect(useMembershipStore.getState().data?.tier).toBe('pro');
    expect(membershipLoad).toHaveBeenCalledTimes(1);
  });

  it('blocks duplicate sign-out and ignores its late completion after a newer flow starts', async () => {
    useAccountStore.setState({ data: signedIn() });
    const signOutResult = deferred<AccountStatus>();
    const signOut = vi.fn(() => signOutResult.promise);
    const start = vi.fn(async () => pending(60_000, 'flow-2'));
    useShellStore.setState({
      bridge: bridge({
        accountSignOut: signOut,
        accountDeviceAuthStart: start,
        openAccountAuthUrl: async () => {}
      })
    });

    const first = useAccountStore.getState().signOut();
    const duplicate = useAccountStore.getState().signOut();
    expect(signOut).toHaveBeenCalledTimes(1);
    await useAccountStore.getState().startDeviceAuth();
    expect(start).not.toHaveBeenCalled();

    useAccountStore.getState().resetAuthAttempt();
    await useAccountStore.getState().startDeviceAuth();
    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
    signOutResult.resolve(signedOut());
    await Promise.all([first, duplicate]);

    expect(useAccountStore.getState().authPhase).toBe('pending');
    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
  });

  it('ignores a late sign-out error after a newer flow starts', async () => {
    const membershipLoad = vi.fn(async () => {});
    useMembershipStore.setState({ load: membershipLoad });
    useAccountStore.setState({ data: signedIn() });
    const signOutResult = deferred<AccountStatus>();
    useShellStore.setState({
      bridge: bridge({
        accountSignOut: () => signOutResult.promise,
        accountDeviceAuthStart: async () => pending(60_000, 'flow-2'),
        openAccountAuthUrl: async () => {}
      })
    });

    const signOut = useAccountStore.getState().signOut();
    useAccountStore.getState().resetAuthAttempt();
    await useAccountStore.getState().startDeviceAuth();
    signOutResult.reject(new Error('old sign-out failed'));
    await signOut;

    expect(useAccountStore.getState().authPhase).toBe('pending');
    expect(useAccountStore.getState().authSession?.flowId).toBe('flow-2');
    expect(useAccountStore.getState().authError).toBeNull();
    expect(membershipLoad).not.toHaveBeenCalled();
  });
});
