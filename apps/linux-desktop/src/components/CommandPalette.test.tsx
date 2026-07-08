// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CommandPalette } from './CommandPalette.js';
import { COMMAND_PALETTE_RECENTS_KEY } from '../commandPaletteRecents.js';
import { useShellStore } from '../state/shellStore.js';

function resetShell(): void {
  localStorage.clear();
  location.hash = '';
  useShellStore.setState({
    route: 'overview',
    skin: 'editorial',
    health: null,
    bridge: null,
    fixtureMode: false
  });
}

describe('CommandPalette', () => {
  beforeEach(resetShell);
  afterEach(cleanup);

  it('does not render when closed', () => {
    render(<CommandPalette open={false} onClose={() => {}} />);
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('lists routes and filters by query', () => {
    render(<CommandPalette open onClose={() => {}} />);
    expect(screen.getByText('Navigate')).toBeTruthy();
    expect(screen.getByRole('button', { name: /Overview/i })).toBeTruthy();

    const input = screen.getByLabelText('Search routes and recent queries');
    fireEvent.change(input, { target: { value: 'missions' } });
    expect(screen.getByRole('button', { name: /Missions/i })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Overview/i })).toBeNull();
  });

  it('navigates on route click and closes', () => {
    const onClose = vi.fn();
    render(<CommandPalette open onClose={onClose} />);
    fireEvent.click(screen.getByRole('button', { name: /Settings/i }));
    expect(useShellStore.getState().route).toBe('settings');
    expect(location.hash).toBe('#/settings');
    expect(onClose).toHaveBeenCalled();
  });

  it('supports keyboard navigation and escape', () => {
    const onClose = vi.fn();
    render(<CommandPalette open onClose={onClose} />);
    const dialog = screen.getByRole('dialog');
    fireEvent.keyDown(dialog, { key: 'ArrowDown' });
    fireEvent.keyDown(dialog, { key: 'Enter' });
    expect(useShellStore.getState().route).toBe('insights');
    onClose.mockClear();
    fireEvent.keyDown(dialog, { key: 'Escape' });
    expect(onClose).toHaveBeenCalled();
  });

  it('shows recent searches in Search section', () => {
    localStorage.setItem(COMMAND_PALETTE_RECENTS_KEY, JSON.stringify(['quota audit']));
    render(<CommandPalette open onClose={() => {}} />);
    expect(screen.getByText('Search')).toBeTruthy();
    expect(screen.getByRole('button', { name: /quota audit/i })).toBeTruthy();
  });

  it('persists recents when navigating with a query', () => {
    render(<CommandPalette open onClose={() => {}} />);
    const input = screen.getByLabelText('Search routes and recent queries');
    fireEvent.change(input, { target: { value: 'providers' } });
    fireEvent.click(screen.getByRole('button', { name: /Providers/i }));
    const stored = JSON.parse(localStorage.getItem(COMMAND_PALETTE_RECENTS_KEY) ?? '[]') as string[];
    expect(stored[0]).toBe('providers');
  });
});