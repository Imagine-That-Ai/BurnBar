// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { LinuxShellBridge, NativeNotificationCapabilities, NativeStatusSnapshot } from '../tauriBridge.js';
import { CompactStatusApp, CompactStatusPanel } from './CompactStatusApp.js';

const snapshot: NativeStatusSnapshot = {
  shell: {
    loginStartEnabled: true,
    loginStartPath: '/home/alice/.config/autostart/dev.openburnbar.OpenBurnBar.desktop',
    backgroundLaunch: false,
    rejectedDeepLinks: 0
  },
  tray: {
    todayCostUsd: 12.5,
    todayTokens: 123456,
    connectedProviders: 3,
    quotaFloorRemainingPercent: 28,
    freshness: 'live'
  }
};

const capabilities: NativeNotificationCapabilities = {
  available: true,
  actions: true,
  persistence: false,
  body: true,
  bodyMarkup: false,
  serverCapabilities: ['actions', 'body']
};

describe('CompactStatusPanel', () => {
  afterEach(cleanup);

  it('renders live daemon facts with stable quick actions', () => {
    const onRoute = vi.fn();
    render(
      <CompactStatusPanel
        snapshot={snapshot}
        capabilities={capabilities}
        onRoute={onRoute}
        onClose={() => {}}
      />
    );
    expect(screen.getByRole('heading', { name: 'Quick status' })).toBeTruthy();
    expect(screen.getByText('$12.50')).toBeTruthy();
    expect(screen.getByText('123,456')).toBeTruthy();
    expect(screen.getByText('28%')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Chat' }));
    expect(onRoute).toHaveBeenCalledWith('chat', 'open-chat');
    fireEvent.click(screen.getByRole('button', { name: 'Reconnect daemon' }));
    expect(onRoute).toHaveBeenCalledWith('support', 'reconnect-daemon');
  });

  it('surfaces degraded notification capability without hiding local values', () => {
    render(
      <CompactStatusPanel
        snapshot={{ ...snapshot, tray: { ...snapshot.tray, freshness: 'stale' } }}
        capabilities={{ ...capabilities, actions: false }}
        onRoute={() => {}}
        onClose={() => {}}
      />
    );
    expect(screen.getByText('Daemon data is stale')).toBeTruthy();
    expect(screen.getByRole('status').textContent).toContain('without action buttons');
  });

  it('uses an accessible close control', () => {
    const onClose = vi.fn();
    render(
      <CompactStatusPanel
        snapshot={snapshot}
        capabilities={capabilities}
        onRoute={() => {}}
        onClose={onClose}
      />
    );
    fireEvent.click(screen.getByRole('button', { name: 'Close status' }));
    expect(onClose).toHaveBeenCalledOnce();
  });
});

describe('CompactStatusApp', () => {
  afterEach(cleanup);

  it('unsubscribes when closed during native listener registration', async () => {
    const unlisten = vi.fn();
    let resolveListen!: (value: () => void) => void;
    const bridge = {
      nativeStatusSnapshot: vi.fn().mockResolvedValue(snapshot),
      nativeNotificationCapabilities: vi.fn().mockResolvedValue(capabilities),
      onNativeStatusSnapshot: vi.fn().mockImplementation(
        () =>
          new Promise<() => void>((resolve) => {
            resolveListen = resolve;
          })
      ),
      nativeStatusClose: vi.fn(),
      nativeStatusRoute: vi.fn()
    } as unknown as LinuxShellBridge;

    const { unmount } = render(<CompactStatusApp bridge={bridge} />);
    await waitFor(() => expect(bridge.onNativeStatusSnapshot).toHaveBeenCalledOnce());

    unmount();
    resolveListen(unlisten);

    await waitFor(() => expect(unlisten).toHaveBeenCalledOnce());
  });
});
