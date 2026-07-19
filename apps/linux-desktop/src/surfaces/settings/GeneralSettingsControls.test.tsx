// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useShellStore } from '../../state/shellStore.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import { DashboardDefaultsControls, IndexingSummaryControl } from './GeneralSettingsControls.js';

function reset() {
  localStorage.clear();
  useShellStore.setState({ bridge: null, fixtureMode: false });
  useDatabaseStore.setState({
    workspace: null,
    loading: false,
    error: null,
    indexAction: { pending: false, error: null, result: null }
  });
}

afterEach(() => {
  cleanup();
  reset();
});

beforeEach(reset);

describe('DashboardDefaultsControls', () => {
  it('uses macOS defaults and persists range and unit choices', () => {
    render(<DashboardDefaultsControls />);

    const range = screen.getByRole('combobox', { name: 'Default dashboard time range' }) as HTMLSelectElement;
    const unit = screen.getByRole('combobox', { name: 'Default dashboard usage display' }) as HTMLSelectElement;
    expect(range.value).toBe('today');
    expect(unit.value).toBe('cost');

    fireEvent.change(range, { target: { value: 'month' } });
    fireEvent.change(unit, { target: { value: 'tokens' } });
    expect(localStorage.getItem('openburnbar.linux.deckTimeRange.v1')).toBe('month');
    expect(localStorage.getItem('openburnbar.linux.deckHeroUnit.v1')).toBe('tokens');
    expect(range.value).toBe('month');
    expect(unit.value).toBe('tokens');
  });
});

describe('IndexingSummaryControl', () => {
  it('fails closed when the packaged shell has no index-status RPC', () => {
    const onOpenDatabase = vi.fn();
    render(<IndexingSummaryControl onOpenDatabase={onOpenDatabase} />);

    expect(screen.getByRole('status', { name: 'Unavailable' })).toBeTruthy();
    expect(screen.getByText(/does not expose the index-status RPC/i)).toBeTruthy();
    expect(onOpenDatabase).not.toHaveBeenCalled();
  });

  it('loads daemon-backed status and keeps project controls in Database', async () => {
    const onOpenDatabase = vi.fn();
    const databaseWorkspaceStatus = vi.fn(async () => ({
      ...(await bridgeStubDefaults.databaseWorkspaceStatus()),
      projectRoot: '/home/alberto/BurnBar',
      artifactCount: 17,
      productionReady: true,
      semanticAvailable: true
    }));
    const databaseIndexProject = vi.fn(async () => ({
      ...(await bridgeStubDefaults.databaseIndexProject()),
      indexedFiles: 17
    }));
    useShellStore.setState({
      bridge: { ...bridgeStubDefaults, databaseWorkspaceStatus, databaseIndexProject } as unknown as LinuxShellBridge,
      fixtureMode: false
    });
    render(<IndexingSummaryControl onOpenDatabase={onOpenDatabase} />);

    await waitFor(() => expect(databaseWorkspaceStatus).toHaveBeenCalledOnce());
    expect(await screen.findByRole('status', { name: 'Ready' })).toBeTruthy();
    expect(screen.getByText(/17 records · semantic search/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Index project' }));
    await waitFor(() => expect(databaseIndexProject).toHaveBeenCalledWith('/home/alberto/BurnBar'));
    expect(await screen.findByText(/Indexed 17 files for test-project/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open Database' }));
    expect(onOpenDatabase).toHaveBeenCalledOnce();
  });

  it('keeps the index action usable in fixture mode', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: true });
    render(<IndexingSummaryControl onOpenDatabase={vi.fn()} />);

    expect(await screen.findByRole('status', { name: 'Ready' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Index project' }));
    expect(await screen.findByText(/Indexed 42 files for fixture-project/i)).toBeTruthy();
  });
});
