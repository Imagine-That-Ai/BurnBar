// @vitest-environment jsdom
import { act, cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { LinuxShellBridge } from '../tauriBridge.js';
import { useShellStore } from '../state/shellStore.js';
import { makeAvailableRuntimeCapabilityManifest } from '../testing/bridgeStubs.js';
import { SurfaceRouter, isPackagedSurfaceMode } from './SurfaceRouter.js';

function setTauriInternals(value: object | undefined): void {
  const target = window as unknown as Record<string, unknown>;
  if (value === undefined) {
    delete target.__TAURI_INTERNALS__;
  } else {
    Object.defineProperty(target, '__TAURI_INTERNALS__', { configurable: true, value });
  }
}

describe('SurfaceRouter packaged body scheduling', () => {
  beforeEach(() => {
    localStorage.clear();
    setTauriInternals(undefined);
    useShellStore.setState({
      route: 'overview',
      bridge: null,
      bridgeReady: true,
      fixtureMode: true,
      runtimeCapabilities: null,
      capabilityError: null,
      health: null,
      healthError: null,
      healthBusy: false
    });
  });

  afterEach(() => {
    setTauriInternals(undefined);
    cleanup();
  });

  it('only defers a non-fixture Tauri surface', () => {
    expect(isPackagedSurfaceMode(false)).toBe(false);
    setTauriInternals({});
    expect(isPackagedSurfaceMode(false)).toBe(true);
    expect(isPackagedSurfaceMode(true)).toBe(false);
  });

  it('paints a packaged skeleton before two frames and idle time', async () => {
    const originalRaf = window.requestAnimationFrame;
    const originalCancelRaf = window.cancelAnimationFrame;
    const originalIdle = (window as Window & {
      requestIdleCallback?: (callback: (deadline: { didTimeout: boolean; timeRemaining(): number }) => void) => number;
    }).requestIdleCallback;
    const originalCancelIdle = (window as Window & { cancelIdleCallback?: (handle: number) => void }).cancelIdleCallback;
    const frames: FrameRequestCallback[] = [];
    let idleCallback: ((deadline: { didTimeout: boolean; timeRemaining(): number }) => void) | undefined;

    setTauriInternals({});
    useShellStore.setState({ fixtureMode: false });
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
      value: () => undefined
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
      value: () => undefined
    });

    try {
      const { container } = render(<SurfaceRouter route="overview" />);
      expect(container.querySelector('.surface-body-skeleton')).not.toBeNull();
      expect(container.querySelector('.overview-atelier')).toBeNull();
      expect(frames).toHaveLength(1);

      await act(async () => {
        frames.shift()?.(16);
      });
      expect(container.querySelector('.overview-atelier')).toBeNull();
      expect(frames).toHaveLength(1);

      await act(async () => {
        frames.shift()?.(32);
      });
      expect(container.querySelector('.overview-atelier')).toBeNull();
      expect(idleCallback).toBeDefined();

      await act(async () => {
        idleCallback?.({ didTimeout: false, timeRemaining: () => 50 });
      });
      expect(container.querySelector('.surface-body-skeleton')).toBeNull();
      expect(container.querySelector('#route-title')?.textContent).toBe('Overview');
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
    }
  });

  it('keeps fixture mode eager even when Tauri internals are present', () => {
    setTauriInternals({});
    const { container } = render(<SurfaceRouter route="overview" />);
    expect(container.querySelector('.surface-body-skeleton')).toBeNull();
    expect(container.querySelector('.overview-atelier')).not.toBeNull();
  });
});

const packagedBridge = {} as LinuxShellBridge;

describe('SurfaceRouter runtime capability boundary', () => {
  beforeEach(() => {
    useShellStore.setState({
      bridge: packagedBridge,
      bridgeReady: true,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      capabilityError: null,
      fixtureMode: false
    });
  });

  afterEach(cleanup);

  it('suppresses workflow controls when the required capability is unavailable', () => {
    const manifest = makeAvailableRuntimeCapabilityManifest();
    const mercury = manifest.capabilities.find((entry) => entry.id === 'media.mercury');
    if (!mercury) throw new Error('missing media.mercury test capability');
    mercury.state = 'unavailable';
    mercury.reason = 'No compatible media transport is installed.';
    mercury.substitute = 'Use a paired macOS peer.';
    useShellStore.setState({ runtimeCapabilities: manifest });

    render(<SurfaceRouter route="mercury" />);
    expect(screen.getByRole('alert').textContent).toContain('Mercury is unavailable');
    expect(screen.getByRole('alert').textContent).toContain('No compatible media transport');
    expect(screen.queryByText(/Pair, call, mirror/)).toBeNull();
  });

  it('renders a degraded route with an explicit limitation notice', () => {
    const manifest = makeAvailableRuntimeCapabilityManifest();
    const pet = manifest.capabilities.find((entry) => entry.id === 'pet.overlay');
    if (!pet) throw new Error('missing pet.overlay test capability');
    pet.state = 'degraded';
    pet.reason = 'Input pass-through is unavailable on this compositor.';
    pet.substitute = 'Use the draggable contained pet.';
    useShellStore.setState({ runtimeCapabilities: manifest });

    render(<SurfaceRouter route="pet" />);
    expect(screen.getByRole('status').textContent).toContain('Limited in this session');
    expect(screen.getByRole('button', { name: 'Wave at preview' })).toBeTruthy();
  });

  it('fails closed when a packaged shell cannot provide the manifest', () => {
    act(() => useShellStore.setState({ runtimeCapabilities: null, capabilityError: 'probe failed' }));
    render(<SurfaceRouter route="chat" />);
    expect(screen.getByRole('status').textContent).toContain('Chat / Hermes is not available yet');
    expect(screen.getByRole('status').textContent).toContain('probe failed');
    expect(screen.queryByText('New chat')).toBeNull();
  });
});
