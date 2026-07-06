// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { KERNEL_META } from '@openburnbar/gl-engine/engine/registry';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { fixtureUsageSummary } from '../daemonFixture.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useShellStore } from '../state/shellStore.js';
import { CommandDeck } from './CommandDeck.js';
import { DEFAULT_LINUX_KERNEL_ID } from '../state/kernelPrefs.js';
import { DECK_PRIMARY_ROUTES } from './deckPrimaryRoutes.js';

function reset(): void {
  localStorage.clear();
  useShellStore.setState({ route: 'overview', skin: 'editorial', fixtureMode: true });
  useOverviewStore.setState({
    summary: fixtureUsageSummary(),
    cacheHitRatePct: null,
    loading: false,
    error: null
  });
}

function deckProps() {
  return {
    onOpenCommandPalette: () => {},
    kernelId: DEFAULT_LINUX_KERNEL_ID,
    onKernelChange: () => {}
  };
}

describe('CommandDeck', () => {
  beforeEach(reset);
  afterEach(cleanup);

  it('renders section switcher and overflow menu', () => {
    render(<CommandDeck {...deckProps()} />);
    expect(screen.getByRole('button', { name: /Overview/ })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'More actions' })).toBeTruthy();
  });

  it('navigates via section menu', () => {
    render(<CommandDeck {...deckProps()} />);
    fireEvent.click(screen.getByRole('button', { name: /Overview/ }));
    fireEvent.click(screen.getByRole('option', { name: /Missions/ }));
    expect(useShellStore.getState().route).toBe('missions');
  });

  it('opens BURN hero popover with unit toggle', () => {
    render(<CommandDeck {...deckProps()} />);
    fireEvent.click(screen.getByLabelText(/BURN .+ Open range and unit controls/));
    fireEvent.click(screen.getByRole('button', { name: 'tok' }));
    expect(localStorage.getItem('openburnbar.linux.deckHeroUnit.v1')).toBe('tokens');
  });

  it('binds ⌘1–⌘7 to primary sections', () => {
    render(<CommandDeck {...deckProps()} />);
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '3', metaKey: true, bubbles: true }));
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES[2]);
  });

  it('lists all registry kernels and persists selection', () => {
    render(<CommandDeck {...deckProps()} />);
    fireEvent.click(screen.getByRole('button', { name: /Swarm Ember/ }));
    const options = screen.getAllByRole('option');
    expect(options.length).toBe(KERNEL_META.length);
    fireEvent.click(screen.getByRole('option', { name: /^Fluid Aurora/ }));
    expect(localStorage.getItem('openburnbar.linux.kernel.v1')).toBe('fluid-aurora');
  });
});