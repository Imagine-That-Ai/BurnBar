// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { fixtureUsageSummary } from '../daemonFixture.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useShellStore } from '../state/shellStore.js';
import { DEFAULT_LINUX_KERNEL_ID } from '../state/kernelPrefs.js';
import { TopChrome } from './TopChrome.js';

function resetShell(): void {
  localStorage.clear();
  window.history.replaceState(null, '', `${location.pathname}${location.search}`);
  useShellStore.setState({
    route: 'overview',
    skin: 'editorial',
    health: null,
    healthError: null,
    healthBusy: false,
    trayDegraded: false,
    bridge: null,
    bridgeReady: true,
    runtimeCapabilities: null,
    capabilityError: null,
    fixtureMode: true
  });
  useOverviewStore.setState({
    summary: fixtureUsageSummary(),
    loading: false,
    error: null,
    cacheHitRatePct: null,
    lastRefreshedAt: null
  });
}

describe('TopChrome accessibility names', () => {
  beforeEach(resetShell);
  afterEach(cleanup);

  it('gives icon-only session, account, and settings actions stable names', () => {
    render(
      <TopChrome
        onOpenCommandPalette={() => {}}
        kernelId={DEFAULT_LINUX_KERNEL_ID}
        onKernelChange={() => {}}
      />
    );

    expect(screen.getByRole('button', { name: 'Import sessions' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Account' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Settings' })).toBeTruthy();
  });

  it('opens the Activity import workflow from the Import sessions action', () => {
    render(
      <TopChrome
        onOpenCommandPalette={() => {}}
        kernelId={DEFAULT_LINUX_KERNEL_ID}
        onKernelChange={() => {}}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Import sessions' }));
    expect(useShellStore.getState().route).toBe('activity');
  });
});
