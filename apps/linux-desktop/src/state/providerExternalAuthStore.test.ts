import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  LinuxShellBridge,
  ProviderExternalAuthFlowSnapshot
} from '../tauriBridge.js';
import { useProvidersStore } from './providersStore.js';
import {
  resetProviderExternalAuthStoreForTests,
  useProviderExternalAuthStore
} from './providerExternalAuthStore.js';
import { useShellStore } from './shellStore.js';
import { useSystemStore } from './systemStore.js';

const NOW = new Date('2026-07-10T12:00:00Z');

function flow(
  state: ProviderExternalAuthFlowSnapshot['state'],
  providerId = 'openai'
): ProviderExternalAuthFlowSnapshot {
  const active = state === 'launching' || state === 'awaiting_user' || state === 'verifying';
  const terminal = state === 'succeeded' || state === 'failed' || state === 'cancelled' || state === 'timed_out';
  return {
    flowId: state === 'idle' ? undefined : `flow-${providerId}`,
    providerId,
    providerDisplayName: providerId === 'anthropic' ? 'Anthropic' : 'OpenAI',
    authMethodId: providerId === 'anthropic'
      ? 'anthropic-claude-code-login'
      : 'openai-codex-oauth',
    authMethodDisplayName: providerId === 'anthropic'
      ? 'Sign in with Claude Code'
      : 'Sign in with OpenAI / Codex',
    cliDisplayName: providerId === 'anthropic' ? 'Claude Code' : 'Codex',
    state,
    availability: 'available',
    cliInstalled: true,
    connected: state === 'succeeded',
    accountDescription: state === 'succeeded' ? 'work@example.com' : undefined,
    startedAt: active || terminal ? NOW.toISOString() : undefined,
    updatedAt: NOW.toISOString(),
    expiresAt: active ? new Date(NOW.getTime() + 60_000).toISOString() : undefined,
    completedAt: terminal ? NOW.toISOString() : undefined
  };
}

function bridge(overrides: Partial<LinuxShellBridge>): LinuxShellBridge {
  return overrides as LinuxShellBridge;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

describe('providerExternalAuthStore', () => {
  const refreshCatalog = vi.fn(async () => {});
  const refreshConfig = vi.fn(async () => {});

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    resetProviderExternalAuthStoreForTests();
    refreshCatalog.mockClear();
    refreshConfig.mockClear();
    useProvidersStore.setState({ load: refreshCatalog });
    useSystemStore.setState({ loadConfig: refreshConfig });
    useShellStore.setState({ fixtureMode: false, bridge: null, bridgeReady: true });
  });

  afterEach(() => {
    resetProviderExternalAuthStoreForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('discovers the registry-backed browser method with provider ID only', async () => {
    const status = vi.fn(async () => flow('idle'));
    useShellStore.setState({ bridge: bridge({ providerExternalAuthStatus: status }) });

    await useProviderExternalAuthStore.getState().load('openai');

    expect(status).toHaveBeenCalledWith({ providerId: 'openai' });
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.authMethodId)
      .toBe('openai-codex-oauth');
  });

  it('starts the discovered method, polls to success, and refreshes provider data once', async () => {
    const status = vi.fn()
      .mockResolvedValueOnce(flow('idle'))
      .mockResolvedValueOnce(flow('succeeded'));
    const start = vi.fn(async () => flow('awaiting_user'));
    useShellStore.setState({
      bridge: bridge({ providerExternalAuthStatus: status, providerExternalAuthStart: start })
    });

    await useProviderExternalAuthStore.getState().load('openai');
    await useProviderExternalAuthStore.getState().start('openai', 'openai-codex-oauth');
    expect(start).toHaveBeenCalledWith({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth'
    });
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('awaiting_user');

    await vi.advanceTimersByTimeAsync(2_000);
    expect(status).toHaveBeenLastCalledWith({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth',
      flowId: 'flow-openai'
    });
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('succeeded');
    expect(refreshCatalog).toHaveBeenCalledTimes(1);
    expect(refreshConfig).toHaveBeenCalledTimes(1);
  });

  it('prevents a second provider flow while one login is active', async () => {
    const start = vi.fn(async () => flow('awaiting_user', 'anthropic'));
    useShellStore.setState({ bridge: bridge({ providerExternalAuthStart: start }) });
    useProviderExternalAuthStore.setState({
      snapshots: { openai: flow('awaiting_user') }
    });

    await useProviderExternalAuthStore.getState().start(
      'anthropic',
      'anthropic-claude-code-login'
    );
    expect(start).not.toHaveBeenCalled();
  });

  it('invalidates a late poll before cancellation so success cannot win', async () => {
    const pendingPoll = deferred<ProviderExternalAuthFlowSnapshot>();
    const status = vi.fn()
      .mockResolvedValueOnce(flow('awaiting_user'))
      .mockImplementationOnce(() => pendingPoll.promise);
    const cancel = vi.fn(async () => flow('cancelled'));
    useShellStore.setState({
      bridge: bridge({ providerExternalAuthStatus: status, providerExternalAuthCancel: cancel })
    });

    await useProviderExternalAuthStore.getState().load('openai');
    await vi.advanceTimersByTimeAsync(2_000);
    const cancellation = useProviderExternalAuthStore.getState().cancel('openai', 'flow-openai');
    pendingPoll.resolve(flow('succeeded'));
    await cancellation;
    await Promise.resolve();

    expect(cancel).toHaveBeenCalledWith('flow-openai');
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('cancelled');
    expect(refreshCatalog).not.toHaveBeenCalled();
  });

  it('resumes polling the daemon-owned flow when cancellation transport fails', async () => {
    const status = vi.fn()
      .mockResolvedValueOnce(flow('awaiting_user'))
      .mockResolvedValueOnce(flow('succeeded'));
    const cancel = vi.fn(async () => {
      throw new Error('socket disconnected');
    });
    useShellStore.setState({
      bridge: bridge({ providerExternalAuthStatus: status, providerExternalAuthCancel: cancel })
    });

    await useProviderExternalAuthStore.getState().load('openai');
    await useProviderExternalAuthStore.getState().cancel('openai', 'flow-openai');
    expect(useProviderExternalAuthStore.getState().errors.openai)
      .toBe('Could not cancel provider sign-in.');

    await vi.advanceTimersByTimeAsync(2_000);
    expect(status).toHaveBeenLastCalledWith({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth',
      flowId: 'flow-openai'
    });
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('succeeded');
    expect(refreshCatalog).toHaveBeenCalledTimes(1);
  });

  it('does not adopt an unrelated flow returned from a bound active poll', async () => {
    const active = { ...flow('awaiting_user'), flowId: 'flow-original' };
    const unrelated = { ...flow('awaiting_user'), flowId: 'flow-replacement' };
    const completed = { ...flow('succeeded'), flowId: 'flow-original' };
    const status = vi.fn()
      .mockResolvedValueOnce(active)
      .mockResolvedValueOnce(unrelated)
      .mockResolvedValueOnce(completed);
    useShellStore.setState({ bridge: bridge({ providerExternalAuthStatus: status }) });

    await useProviderExternalAuthStore.getState().load('openai');
    await vi.advanceTimersByTimeAsync(2_000);

    expect(status).toHaveBeenLastCalledWith({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth',
      flowId: 'flow-original'
    });
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.flowId)
      .toBe('flow-original');
    expect(useProviderExternalAuthStore.getState().errors.openai)
      .toBe('Provider sign-in status check failed; retrying.');

    await vi.advanceTimersByTimeAsync(4_000);
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('succeeded');
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.flowId)
      .toBe('flow-original');
  });

  it('does not let a stale poll replace a newly resumed flow generation', async () => {
    const pendingPoll = deferred<ProviderExternalAuthFlowSnapshot>();
    const original = { ...flow('awaiting_user'), flowId: 'flow-original' };
    const replacement = { ...flow('awaiting_user'), flowId: 'flow-replacement' };
    const status = vi.fn()
      .mockResolvedValueOnce(original)
      .mockImplementationOnce(() => pendingPoll.promise)
      .mockResolvedValueOnce(replacement);
    useShellStore.setState({ bridge: bridge({ providerExternalAuthStatus: status }) });

    await useProviderExternalAuthStore.getState().load('openai');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(status).toHaveBeenLastCalledWith({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth',
      flowId: 'flow-original'
    });

    await useProviderExternalAuthStore.getState().load('openai');
    expect(status).toHaveBeenLastCalledWith({ providerId: 'openai' });
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.flowId)
      .toBe('flow-replacement');

    pendingPoll.resolve({ ...flow('succeeded'), flowId: 'flow-original' });
    await Promise.resolve();
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('awaiting_user');
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.flowId)
      .toBe('flow-replacement');
    expect(refreshCatalog).not.toHaveBeenCalled();
  });

  it('keeps the daemon-owned flow alive through a transient status failure', async () => {
    const status = vi.fn()
      .mockResolvedValueOnce(flow('awaiting_user'))
      .mockRejectedValueOnce(new Error('/tmp/private-command failed'))
      .mockResolvedValueOnce(flow('succeeded'));
    useShellStore.setState({ bridge: bridge({ providerExternalAuthStatus: status }) });

    await useProviderExternalAuthStore.getState().load('openai');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(useProviderExternalAuthStore.getState().errors.openai)
      .toBe('Provider sign-in status check failed; retrying.');
    expect(useProviderExternalAuthStore.getState().errors.openai).not.toContain('/tmp');

    await vi.advanceTimersByTimeAsync(4_000);
    expect(useProviderExternalAuthStore.getState().snapshots.openai?.state).toBe('succeeded');
  });
});
