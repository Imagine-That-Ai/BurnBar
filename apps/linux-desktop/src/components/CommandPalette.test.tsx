// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useState } from 'react';
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

  it('exposes combobox and actionable active command semantics while moving with arrows', () => {
    render(<CommandPalette open onClose={() => {}} />);
    const input = screen.getByRole('combobox', { name: 'Search routes and recent queries' });
    const options = screen.getAllByRole('button', { name: /.+/i });
    expect(options.every((option) => option.tagName === 'BUTTON')).toBe(true);

    expect(input.getAttribute('aria-controls')).toBe(screen.getByRole('listbox', { name: 'Command results' }).id);
    expect(input.getAttribute('aria-activedescendant')).toBe(options[0].id);
    expect(options[0].getAttribute('aria-current')).toBe('true');

    fireEvent.keyDown(input, { key: 'ArrowDown' });
    expect(input.getAttribute('aria-activedescendant')).toBe(options[1].id);
    expect(options[1].getAttribute('aria-current')).toBe('true');
    expect(options[0].getAttribute('aria-current')).toBeNull();
  });

  it('traps tab focus and returns focus to the opener after dismissal', async () => {
    function Harness() {
      const [open, setOpen] = useState(false);
      return (
        <>
          <button type="button" onClick={() => setOpen(true)}>Open palette</button>
          <CommandPalette open={open} onClose={() => setOpen(false)} />
        </>
      );
    }

    render(<Harness />);
    const opener = screen.getByRole('button', { name: 'Open palette' });
    opener.focus();
    fireEvent.click(opener);
    const input = await screen.findByRole('combobox', { name: 'Search routes and recent queries' });
    await waitFor(() => expect(document.activeElement).toBe(input));

    fireEvent.keyDown(input, { key: 'Tab', shiftKey: true });
    const commandButtons = screen.getAllByRole('button', { name: /.+/i });
    expect(document.activeElement).toBe(commandButtons[commandButtons.length - 1]);

    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
    await waitFor(() => expect(document.activeElement).toBe(opener));
  });
});
