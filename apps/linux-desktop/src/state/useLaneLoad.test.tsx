// @vitest-environment jsdom
import { act, cleanup, render } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from './shellStore.js';
import { useLaneLoad } from './useLaneLoad.js';

function Probe({ load }: { load: () => Promise<void> }) {
  useLaneLoad(load);
  return null;
}

describe('useLaneLoad', () => {
  beforeEach(() => {
    localStorage.clear();
    useShellStore.setState({
      bridge: null,
      bridgeReady: false,
      fixtureMode: false,
      health: null,
      healthError: null,
      healthBusy: false,
      dataRevision: 0,
      lastDaemonEventAt: null,
      subscriptionRecoveredAfterRestart: false,
      subscriptionState: 'stopped',
      subscriptionError: null
    });
  });
  afterEach(cleanup);

  it('fires load on mount and re-fires when bridgeReady flips to true', async () => {
    const spy = vi.fn(() => Promise.resolve());
    render(<Probe load={spy} />);

    // Initial mount fires once.
    expect(spy).toHaveBeenCalledTimes(1);
    await act(async () => { await Promise.resolve(); });

    // Simulate boot completing: bridge becomes available, bridgeReady flips.
    act(() => {
      useShellStore.setState({ bridgeReady: true });
    });

    // The re-fire is the entire point — without bridgeReady in the dep
    // array this second call never happens and every lane sticks offline.
    await act(async () => { await Promise.resolve(); });
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it('does not re-fire when bridgeReady stays false', () => {
    const spy = vi.fn(() => Promise.resolve());
    render(<Probe load={spy} />);
    expect(spy).toHaveBeenCalledTimes(1);

    // An unrelated state change must not trigger a spurious re-fire.
    act(() => {
      useShellStore.setState({ healthBusy: true });
    });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('re-fires when the daemon data revision advances', async () => {
    const spy = vi.fn(() => Promise.resolve());
    render(<Probe load={spy} />);
    await act(async () => { await Promise.resolve(); });

    act(() => {
      useShellStore.setState({ dataRevision: 1 });
    });

    await act(async () => { await Promise.resolve(); });
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it('coalesces revisions while a load is in flight', async () => {
    let resolveLoad: (() => void) | undefined;
    const spy = vi.fn(() => new Promise<void>((resolve) => { resolveLoad = resolve; }));
    render(<Probe load={spy} />);
    expect(spy).toHaveBeenCalledTimes(1);

    act(() => {
      useShellStore.setState({ dataRevision: 1 });
      useShellStore.setState({ dataRevision: 2 });
    });
    expect(spy).toHaveBeenCalledTimes(1);

    await act(async () => {
      resolveLoad?.();
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(2);
  });
});
