// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DeckSectionSwitcher } from './DeckSectionSwitcher.js';
import { DECK_PRIMARY_ROUTES } from './deckPrimaryRoutes.js';
import { useShellStore } from '../state/shellStore.js';

function resetShell(route: 'chat' | 'providers' = 'chat'): void {
  location.hash = `#/${route}`;
  useShellStore.setState({ route });
}

describe('DeckSectionSwitcher keyboard accessibility', () => {
  beforeEach(() => resetShell());
  afterEach(cleanup);

  it('moves focus into the listbox and marks the current option when opened', () => {
    render(<DeckSectionSwitcher />);
    const trigger = screen.getByRole('button', { name: /chat \/ hermes/i });

    fireEvent.click(trigger);

    const options = screen.getAllByRole('option');
    const selected = options.find((option) => option.getAttribute('aria-selected') === 'true');
    expect(selected).toBeTruthy();
    expect(document.activeElement).toBe(selected);
    expect(selected?.tabIndex).toBe(0);
    expect(options.filter((option) => option.tabIndex === 0)).toEqual([selected]);
  });

  it('supports roving Arrow/Home/End navigation and activates with Enter or Space', () => {
    render(<DeckSectionSwitcher />);
    const trigger = screen.getByRole('button', { name: /chat \/ hermes/i });
    fireEvent.click(trigger);
    const options = screen.getAllByRole('option');
    const selectedIndex = options.findIndex((option) => option.getAttribute('aria-selected') === 'true');
    const selected = options[selectedIndex];
    const next = options[(selectedIndex + 1) % options.length];

    fireEvent.keyDown(selected, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(next);
    fireEvent.keyDown(next, { key: 'End' });
    expect(document.activeElement).toBe(options.at(-1));
    fireEvent.keyDown(options.at(-1)!, { key: 'Home' });
    expect(document.activeElement).toBe(options[0]);
    fireEvent.keyDown(options[0], { key: 'ArrowUp' });
    expect(document.activeElement).toBe(options.at(-1));

    fireEvent.keyDown(options.at(-1)!, { key: ' ' });
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES.at(-1));
    expect(document.activeElement).toBe(trigger);
    expect(screen.queryByRole('option')).toBeNull();
  });

  it('restores trigger focus when Escape closes the listbox', () => {
    render(<DeckSectionSwitcher />);
    const trigger = screen.getByRole('button', { name: /chat \/ hermes/i });
    fireEvent.keyDown(trigger, { key: 'ArrowDown' });
    const options = screen.getAllByRole('option');
    const selected = options.find((option) => option.getAttribute('aria-selected') === 'true');

    expect(selected).toBeTruthy();
    expect(document.activeElement).toBe(selected);
    fireEvent.keyDown(selected!, { key: 'Escape' });

    expect(screen.queryByRole('option')).toBeNull();
    expect(document.activeElement).toBe(trigger);
  });
});
