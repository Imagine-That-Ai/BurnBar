import { afterEach, describe, expect, it, vi } from 'vitest';
import { DaemonHealthSupervisor } from './daemonHealthSupervisor.js';

describe('DaemonHealthSupervisor', () => {
  afterEach(() => vi.useRealTimers());

  it('uses foreground/background cadence without overlapping probes', async () => {
    vi.useFakeTimers();
    let foreground = true;
    const pending: { resolve?: (healthy: boolean) => void } = {};
    const probe = vi.fn(() => new Promise<boolean>((resolve) => { pending.resolve = resolve; }));
    const supervisor = new DaemonHealthSupervisor(probe, {
      activeIntervalMs: 100,
      backgroundIntervalMs: 500,
      isForeground: () => foreground
    });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(probe).toHaveBeenCalledTimes(1);
    supervisor.wake();
    supervisor.wake();
    expect(probe).toHaveBeenCalledTimes(1);
    pending.resolve?.(true);
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(0);
    expect(probe).toHaveBeenCalledTimes(2);
    pending.resolve?.(true);
    await Promise.resolve();
    foreground = false;
    await vi.advanceTimersByTimeAsync(99);
    expect(probe).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(probe).toHaveBeenCalledTimes(3);
    pending.resolve?.(true);
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(499);
    expect(probe).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(probe).toHaveBeenCalledTimes(4);
    supervisor.stop();
  });

  it('backs off failed probes and caps the retry delay', async () => {
    vi.useFakeTimers();
    const probe = vi.fn().mockResolvedValue(false);
    const supervisor = new DaemonHealthSupervisor(probe, {
      failureBaseMs: 10,
      failureMaxMs: 25
    });

    supervisor.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(probe).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(10);
    expect(probe).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(20);
    expect(probe).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(24);
    expect(probe).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(probe).toHaveBeenCalledTimes(4);
    supervisor.stop();
  });
});
