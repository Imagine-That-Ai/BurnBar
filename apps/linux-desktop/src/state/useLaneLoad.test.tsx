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
      healthBusy: false
    });
  });
  afterEach(cleanup);

  it('fires load on mount and re-fires when bridgeReady flips to true', () => {
    const spy = vi.fn(() => Promise.resolve());
    render(<Probe load={spy} />);

    // Initial mount fires once.
    expect(spy).toHaveBeenCalledTimes(1);

    // Simulate boot completing: bridge becomes available, bridgeReady flips.
    act(() => {
      useShellStore.setState({ bridgeReady: true });
    });

    // The re-fire is the entire point — without bridgeReady in the dep
    // array this second call never happens and every lane sticks offline.
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
});
