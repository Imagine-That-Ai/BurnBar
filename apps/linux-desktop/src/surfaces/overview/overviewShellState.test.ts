import { describe, expect, it } from 'vitest';
import { resolveOverviewShellState } from '../OverviewSurface.js';

describe('resolveOverviewShellState (VAL-DASHBOARD-003)', () => {
  it('maps offlineNoBridge to offline', () => {
    expect(
      resolveOverviewShellState({
        offlineNoBridge: true,
        daemonOffline: false,
        error: null,
        busy: false,
        hasSummary: false
      })
    ).toBe('offline');
  });

  it('maps daemonOffline to offline', () => {
    expect(
      resolveOverviewShellState({
        offlineNoBridge: false,
        daemonOffline: true,
        error: null,
        busy: false,
        hasSummary: true
      })
    ).toBe('offline');
  });

  it('maps busy without summary to loading', () => {
    expect(
      resolveOverviewShellState({
        offlineNoBridge: false,
        daemonOffline: false,
        error: null,
        busy: true,
        hasSummary: false
      })
    ).toBe('loading');
  });

  it('maps error without summary to error', () => {
    expect(
      resolveOverviewShellState({
        offlineNoBridge: false,
        daemonOffline: false,
        error: 'boom',
        busy: false,
        hasSummary: false
      })
    ).toBe('error');
  });

  it('maps empty idle to empty', () => {
    expect(
      resolveOverviewShellState({
        offlineNoBridge: false,
        daemonOffline: false,
        error: null,
        busy: false,
        hasSummary: false
      })
    ).toBe('empty');
  });

  it('maps summary present to populated', () => {
    expect(
      resolveOverviewShellState({
        offlineNoBridge: false,
        daemonOffline: false,
        error: null,
        busy: false,
        hasSummary: true
      })
    ).toBe('populated');
  });
});
