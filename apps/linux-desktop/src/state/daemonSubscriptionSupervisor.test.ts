import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  DaemonSubscriptionResponse,
  LinuxShellBridge
} from '../tauriBridge.js';
import { DaemonSubscriptionSupervisor } from './daemonSubscriptionSupervisor.js';

type SubscriptionBridge = Pick<
  LinuxShellBridge,
  'subscriptionStart' | 'subscriptionResume' | 'subscriptionStop'
>;

function response(
  seq: number,
  overrides: Partial<DaemonSubscriptionResponse> = {}
): DaemonSubscriptionResponse {
  return {
    subscriptionId: 'sub-data',
    topic: 'data',
    seq,
    cursor: String(seq),
    firstSnapshot: seq === 1,
    events: [{ seq, kind: seq === 1 ? 'data.snapshot' : 'data.tick', snapshot: {}, terminal: false }],
    degradedFallback: true,
    degradationReason: 'bounded_pull_over_burnbarrpc_envelope',
    backpressure: 'coalesce_latest_per_topic',
    disconnectDetected: false,
    recoveredAfterRestart: false,
    terminalStateDelivered: false,
    ...overrides
  };
}

function makeBridge(): SubscriptionBridge {
  return {
    subscriptionStart: vi.fn().mockResolvedValue(response(1)),
    subscriptionResume: vi.fn().mockImplementation((request) =>
      Promise.resolve(response(request.after_seq + 1))
    ),
    subscriptionStop: vi.fn().mockResolvedValue({
      subscriptionId: 'sub-data',
      stopped: true,
      lastSeq: 1
    })
  };
}

describe('DaemonSubscriptionSupervisor', () => {
  afterEach(() => vi.useRealTimers());

  it('starts once, resumes with a monotonic cursor, and changes cadence in background', async () => {
    vi.useFakeTimers();
    let foreground = true;
    const bridge = makeBridge();
    const onEvent = vi.fn();
    const supervisor = new DaemonSubscriptionSupervisor(bridge, onEvent, {
      activeIntervalMs: 100,
      backgroundIntervalMs: 500,
      isForeground: () => foreground
    });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(1);
    expect(onEvent).toHaveBeenCalledWith(expect.objectContaining({ seq: 1 }));

    foreground = false;
    await vi.advanceTimersByTimeAsync(100);
    expect(bridge.subscriptionResume).toHaveBeenCalledWith(expect.objectContaining({ after_seq: 1 }));
    await vi.advanceTimersByTimeAsync(499);
    expect(bridge.subscriptionResume).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(bridge.subscriptionResume).toHaveBeenCalledTimes(2);
    supervisor.stop();
  });

  it('coalesces wakes while a request is in flight', async () => {
    vi.useFakeTimers();
    let resolveStart: ((value: DaemonSubscriptionResponse) => void) | undefined;
    const bridge = makeBridge();
    vi.mocked(bridge.subscriptionStart).mockImplementation(
      () => new Promise((resolve) => { resolveStart = resolve; })
    );
    const supervisor = new DaemonSubscriptionSupervisor(bridge, vi.fn());

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    supervisor.wake();
    supervisor.wake();
    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(1);
    resolveStart?.(response(1));
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(0);
    expect(bridge.subscriptionResume).toHaveBeenCalledTimes(1);
    supervisor.stop();
  });

  it('backs off failures and caps retries', async () => {
    vi.useFakeTimers();
    const bridge = makeBridge();
    vi.mocked(bridge.subscriptionStart).mockRejectedValue(new Error('offline daemon'));
    const supervisor = new DaemonSubscriptionSupervisor(bridge, vi.fn(), {
      failureBaseMs: 10,
      failureMaxMs: 25
    });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(10);
    await vi.advanceTimersByTimeAsync(20);
    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(24);
    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(4);
    supervisor.stop();
  });

  it('pauses requests offline and wakes immediately when connectivity returns', async () => {
    vi.useFakeTimers();
    let online = false;
    const bridge = makeBridge();
    const supervisor = new DaemonSubscriptionSupervisor(bridge, vi.fn(), {
      isOnline: () => online,
      activeIntervalMs: 100
    });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(bridge.subscriptionStart).not.toHaveBeenCalled();
    online = true;
    supervisor.wake();
    await vi.advanceTimersByTimeAsync(0);
    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(1);
    supervisor.stop();
  });

  it('accepts daemon restart recovery and sends a remote stop during cancellation', async () => {
    vi.useFakeTimers();
    const bridge = makeBridge();
    vi.mocked(bridge.subscriptionResume).mockResolvedValue(
      response(2, { disconnectDetected: true, recoveredAfterRestart: true, firstSnapshot: true })
    );
    const onEvent = vi.fn();
    const supervisor = new DaemonSubscriptionSupervisor(bridge, onEvent, { activeIntervalMs: 10 });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(10);
    expect(onEvent).toHaveBeenLastCalledWith(
      expect.objectContaining({ recoveredAfterRestart: true })
    );
    supervisor.stop();
    await Promise.resolve();
    expect(bridge.subscriptionStop).toHaveBeenCalledWith({
      subscription_id: 'sub-data',
      client_id: 'linux-desktop-shell'
    });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(bridge.subscriptionResume).toHaveBeenCalledTimes(1);
  });

  it('starts a fresh subscription after stop instead of resuming the old cursor', async () => {
    vi.useFakeTimers();
    const bridge = makeBridge();
    const supervisor = new DaemonSubscriptionSupervisor(bridge, vi.fn());

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    supervisor.stop();
    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);

    expect(bridge.subscriptionStart).toHaveBeenCalledTimes(2);
    expect(bridge.subscriptionResume).not.toHaveBeenCalled();
    supervisor.stop();
  });

  it('drops an in-flight response from a previous lifecycle before publishing it', async () => {
    vi.useFakeTimers();
    let resolveFirst: ((value: DaemonSubscriptionResponse) => void) | undefined;
    const bridge = makeBridge();
    vi.mocked(bridge.subscriptionStart)
      .mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
      .mockResolvedValueOnce(response(1, { subscriptionId: 'sub-new' }));
    const onEvent = vi.fn();
    const supervisor = new DaemonSubscriptionSupervisor(bridge, onEvent);

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    supervisor.stop();
    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);

    resolveFirst?.(response(1, { subscriptionId: 'sub-old' }));
    await Promise.resolve();
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(0);
    await Promise.resolve();

    expect(onEvent).toHaveBeenCalledTimes(1);
    expect(onEvent).toHaveBeenLastCalledWith(expect.objectContaining({ subscriptionId: 'sub-new' }));
    expect(bridge.subscriptionStop).toHaveBeenCalledWith({
      subscription_id: 'sub-old',
      client_id: 'linux-desktop-shell'
    });
    supervisor.stop();
  });

  it('cancels a subscription that starts after shutdown was requested', async () => {
    vi.useFakeTimers();
    let resolveStart: ((value: DaemonSubscriptionResponse) => void) | undefined;
    const bridge = makeBridge();
    vi.mocked(bridge.subscriptionStart).mockImplementation(
      () => new Promise((resolve) => { resolveStart = resolve; })
    );
    const onEvent = vi.fn();
    const onStatus = vi.fn();
    const supervisor = new DaemonSubscriptionSupervisor(bridge, onEvent, { onStatus });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    supervisor.stop();
    resolveStart?.(response(1));
    await Promise.resolve();
    await Promise.resolve();

    expect(onEvent).not.toHaveBeenCalled();
    expect(onStatus).toHaveBeenLastCalledWith({ state: 'stopped' });
    expect(bridge.subscriptionStop).toHaveBeenCalledWith({
      subscription_id: 'sub-data',
      client_id: 'linux-desktop-shell'
    });
  });
});
