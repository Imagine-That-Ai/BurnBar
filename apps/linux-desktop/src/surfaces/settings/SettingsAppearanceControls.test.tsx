// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { SettingsAppearanceControls } from './SettingsAppearanceControls.js';

describe('SettingsAppearanceControls accessibility', () => {
  beforeEach(() => {
    localStorage.clear();
    useShellStore.setState({ skin: 'editorial' });
  });

  afterEach(() => {
    cleanup();
    localStorage.clear();
  });

  it('uses a roving tab stop and supports arrow, Home, and End navigation', () => {
    render(<SettingsAppearanceControls />);

    const group = screen.getByRole('radiogroup', { name: 'Color scheme' });
    const options = screen.getAllByRole('radio');
    const [system, light, dark] = options;

    expect(group.getAttribute('aria-orientation')).toBe('horizontal');
    expect(system?.getAttribute('tabindex')).toBe('0');
    expect(light?.getAttribute('tabindex')).toBe('-1');
    expect(dark?.getAttribute('tabindex')).toBe('-1');

    system?.focus();
    fireEvent.keyDown(system!, { key: 'ArrowRight' });
    expect(light?.getAttribute('aria-checked')).toBe('true');
    expect(document.activeElement).toBe(light);

    fireEvent.keyDown(light!, { key: 'End' });
    expect(dark?.getAttribute('aria-checked')).toBe('true');
    expect(document.activeElement).toBe(dark);

    fireEvent.keyDown(dark!, { key: 'ArrowLeft' });
    expect(light?.getAttribute('aria-checked')).toBe('true');
    expect(document.activeElement).toBe(light);
  });

  it('uses the same keyboard contract for the app-skin radiogroup', () => {
    render(<SettingsAppearanceControls />);

    const group = screen.getByRole('radiogroup', { name: 'App skin' });
    const options = screen.getAllByRole('radio').slice(3);
    const [editorial, aurora] = options;

    expect(group.getAttribute('aria-orientation')).toBe('horizontal');
    expect(editorial?.getAttribute('tabindex')).toBe('0');
    expect(aurora?.getAttribute('tabindex')).toBe('-1');

    editorial?.focus();
    fireEvent.keyDown(editorial!, { key: 'ArrowRight' });
    expect(aurora?.getAttribute('aria-checked')).toBe('true');
    expect(document.activeElement).toBe(aurora);
    expect(useShellStore.getState().skin).toBe('aurora');
  });
});
