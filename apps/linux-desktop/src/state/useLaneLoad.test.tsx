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

  it('defers packaged-shell hydration until after two frames and idle time', async () => {
    const originalRaf = window.requestAnimationFrame;
    const originalCancelRaf = window.cancelAnimationFrame;
    const idleWindow = window as Window & {
      requestIdleCallback?: (callback: (deadline: { didTimeout: boolean; timeRemaining(): number }) => void) => number;
      cancelIdleCallback?: (handle: number) => void;
    };
    const originalIdle = idleWindow.requestIdleCallback;
    const originalCancelIdle = idleWindow.cancelIdleCallback;
    const originalTauri = (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
    const frames: FrameRequestCallback[] = [];
    let idleCallback: ((deadline: { didTimeout: boolean; timeRemaining(): number }) => void) | undefined;
    const cancelAnimationFrame = vi.fn();

    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} });
    Object.defineProperty(window, 'requestAnimationFrame', {
      configurable: true,
      writable: true,
      value: (callback: FrameRequestCallback) => {
        frames.push(callback);
        return frames.length;
      }
    });
    Object.defineProperty(window, 'cancelAnimationFrame', {
      configurable: true,
      writable: true,
      value: cancelAnimationFrame
    });
    Object.defineProperty(window, 'requestIdleCallback', {
      configurable: true,
      writable: true,
      value: (callback: (deadline: { didTimeout: boolean; timeRemaining(): number }) => void) => {
        idleCallback = callback;
        return 1;
      }
    });
    Object.defineProperty(window, 'cancelIdleCallback', {
      configurable: true,
      writable: true,
      value: vi.fn()
    });

    try {
      const spy = vi.fn(() => Promise.resolve());
      render(<Probe load={spy} />);
      expect(spy).not.toHaveBeenCalled();
      expect(frames).toHaveLength(1);

      // Subscription events can arrive before the deferred first load. They
      // must not cancel the only pending hydration attempt.
      act(() => {
        useShellStore.setState({ dataRevision: 1 });
        useShellStore.setState({ dataRevision: 2 });
      });
      expect(frames).toHaveLength(1);
      expect(cancelAnimationFrame).not.toHaveBeenCalled();

      await act(async () => {
        frames.shift()?.(16);
      });
      expect(spy).not.toHaveBeenCalled();
      expect(frames).toHaveLength(1);

      act(() => {
        useShellStore.setState({ dataRevision: 3 });
        useShellStore.setState({ dataRevision: 4 });
      });
      expect(frames).toHaveLength(1);
      expect(cancelAnimationFrame).not.toHaveBeenCalled();

      await act(async () => {
        frames.shift()?.(32);
      });
      expect(spy).not.toHaveBeenCalled();
      expect(idleCallback).toBeDefined();

      await act(async () => {
        idleCallback?.({ didTimeout: false, timeRemaining: () => 50 });
        await Promise.resolve();
      });
      expect(spy).toHaveBeenCalledTimes(1);
    } finally {
      Object.defineProperty(window, 'requestAnimationFrame', {
        configurable: true,
        writable: true,
        value: originalRaf
      });
      Object.defineProperty(window, 'cancelAnimationFrame', {
        configurable: true,
        writable: true,
        value: originalCancelRaf
      });
      if (originalIdle) {
        Object.defineProperty(window, 'requestIdleCallback', {
          configurable: true,
          writable: true,
          value: originalIdle
        });
      } else {
        delete (window as unknown as Record<string, unknown>).requestIdleCallback;
      }
      if (originalCancelIdle) {
        Object.defineProperty(window, 'cancelIdleCallback', {
          configurable: true,
          writable: true,
          value: originalCancelIdle
        });
      } else {
        delete (window as unknown as Record<string, unknown>).cancelIdleCallback;
      }
      if (originalTauri === undefined) {
        delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
      } else {
        Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: originalTauri });
      }
    }
  });
});
