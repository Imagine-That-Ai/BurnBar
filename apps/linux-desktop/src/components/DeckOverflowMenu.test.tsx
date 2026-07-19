// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../state/shellStore.js';
import { DeckOverflowMenu } from './DeckOverflowMenu.js';

describe('DeckOverflowMenu accessibility', () => {
  beforeEach(() => {
    localStorage.clear();
    useShellStore.setState({ route: 'overview' });
  });

  afterEach(() => cleanup());

  it('moves focus into the menu and supports list navigation with focus restoration', () => {
    const trigger = () => screen.getByRole('button', { name: 'More actions' });
    render(<DeckOverflowMenu />);

    fireEvent.keyDown(trigger(), { key: 'ArrowDown' });
    expect(trigger().getAttribute('aria-expanded')).toBe('true');
    const radios = screen.getAllByRole('menuitemradio');
    expect(document.activeElement).toBe(radios[0]);

    fireEvent.keyDown(radios[0], { key: 'ArrowDown' });
    expect(document.activeElement).toBe(radios[1]);
    fireEvent.keyDown(radios[1], { key: 'End' });
    const items = screen.getAllByRole('menuitem');
    expect(document.activeElement).toBe(items[items.length - 1]);

    fireEvent.keyDown(document.activeElement as HTMLElement, { key: 'Escape' });
    expect(trigger().getAttribute('aria-expanded')).toBe('false');
    expect(document.activeElement).toBe(trigger());
  });

  it('activates menu actions from the keyboard and restores focus', () => {
    const onImportSessions = vi.fn();
    render(<DeckOverflowMenu onImportSessions={onImportSessions} />);
    const trigger = screen.getByRole('button', { name: 'More actions' });

    fireEvent.click(trigger);
    const menu = screen.getByRole('menu');
    const importItem = screen.getByRole('menuitem', { name: 'Import sessions' });
    importItem.focus();
    fireEvent.keyDown(importItem, { key: 'Enter' });

    expect(onImportSessions).toHaveBeenCalledOnce();
    expect(menu.isConnected).toBe(false);
    expect(document.activeElement).toBe(trigger);
  });
});
