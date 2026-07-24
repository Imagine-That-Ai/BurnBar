// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { TopTabbar } from './TopTabbar.js';
import { DECK_PRIMARY_ROUTES } from './deckPrimaryRoutes.js';
import { useShellStore } from '../state/shellStore.js';

function resetShell(route: 'overview' | 'chat' = 'overview'): void {
  location.hash = `#/${route}`;
  useShellStore.setState({ route });
}

describe('TopTabbar keyboard accessibility', () => {
  beforeEach(() => resetShell());
  afterEach(cleanup);

  it('keeps one tab stop when the current route is outside the primary strip', () => {
    render(<TopTabbar />);
    const tabs = screen.getAllByRole('tab');

    expect(tabs).toHaveLength(DECK_PRIMARY_ROUTES.length);
    expect(tabs.filter((tab) => tab.tabIndex === 0)).toHaveLength(1);
    expect(tabs[0].tabIndex).toBe(0);
    expect(tabs.slice(1).every((tab) => tab.tabIndex === -1)).toBe(true);
  });

  it('moves focus, activates the route, and wraps with horizontal arrows', () => {
    resetShell('chat');
    render(<TopTabbar />);
    const tabs = screen.getAllByRole('tab');

    expect(tabs[0].getAttribute('aria-selected')).toBe('true');
    fireEvent.keyDown(tabs[0], { key: 'ArrowRight' });
    expect(document.activeElement).toBe(tabs[1]);
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES[1]);
    expect(tabs[1].getAttribute('aria-selected')).toBe('true');
    expect(tabs[0].tabIndex).toBe(-1);

    fireEvent.keyDown(tabs[1], { key: 'ArrowLeft' });
    expect(document.activeElement).toBe(tabs[0]);
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES[0]);

    fireEvent.keyDown(tabs[0], { key: 'ArrowLeft' });
    expect(document.activeElement).toBe(tabs[DECK_PRIMARY_ROUTES.length - 1]);
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES[DECK_PRIMARY_ROUTES.length - 1]);
  });

  it('supports Home and End without creating an extra browser tab stop', () => {
    resetShell('chat');
    render(<TopTabbar />);
    const tabs = screen.getAllByRole('tab');

    fireEvent.keyDown(tabs[0], { key: 'End' });
    expect(document.activeElement).toBe(tabs[tabs.length - 1]);
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES.at(-1));
    expect(tabs.filter((tab) => tab.tabIndex === 0)).toHaveLength(1);

    fireEvent.keyDown(tabs[tabs.length - 1], { key: 'Home' });
    expect(document.activeElement).toBe(tabs[0]);
    expect(useShellStore.getState().route).toBe(DECK_PRIMARY_ROUTES[0]);
    expect(tabs.filter((tab) => tab.tabIndex === 0)).toHaveLength(1);
  });
});
