// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { SettingsAppearanceControls } from './SettingsAppearanceControls.js';

describe('SettingsAppearanceControls accessibility', () => {
  beforeEach(() => {
    localStorage.clear();
    delete document.documentElement.dataset.glassTransparency;
    delete document.documentElement.dataset.wallpaper;
    localStorage.removeItem('openburnbar.linux.swarm.v1');
    useShellStore.setState({ skin: 'editorial' });
  });

  afterEach(() => {
    cleanup();
    localStorage.clear();
    delete document.documentElement.dataset.glassTransparency;
    delete document.documentElement.dataset.wallpaper;
    localStorage.removeItem('openburnbar.linux.swarm.v1');
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

  it('persists the continuous Liquid Glass transparency control', () => {
    render(<SettingsAppearanceControls />);

    const range = screen.getByRole('slider', { name: 'Liquid Glass transparency' });
    const output = () => document.querySelector('output[for="glass-transparency-range"]');
    expect((range as HTMLInputElement).value).toBe('0');
    expect(range.getAttribute('step')).toBe('0.01');
    expect(output()?.textContent).toBe('System default');

    fireEvent.change(range, { target: { value: '-0.75' } });
    expect((range as HTMLInputElement).value).toBe('-0.75');
    expect(output()?.textContent).toBe('75% frostier than system');
    expect(range.getAttribute('aria-valuetext')).toBe('75% frostier than system');
    expect(localStorage.getItem('openburnbar.linux.glassTransparency.v1')).toBe('-0.75');
    expect(document.documentElement.dataset.glassTransparency).toBe('frostier');
    expect(document.documentElement.style.getPropertyValue('--glass-tint-base-opacity')).toBe('60%');

    fireEvent.change(range, { target: { value: '0.5' } });
    expect(output()?.textContent).toBe('50% clearer than system');
    expect(localStorage.getItem('openburnbar.linux.glassTransparency.v1')).toBe('0.5');
    expect(document.documentElement.dataset.glassTransparency).toBe('clearer');
  });

  it('persists and applies the desktop wallpaper palette', () => {
    render(<SettingsAppearanceControls />);
    const select = screen.getByRole('combobox', { name: 'Desktop wallpaper palette' });
    fireEvent.change(select, { target: { value: 'auroraTeal' } });
    expect((select as HTMLSelectElement).value).toBe('auroraTeal');
    expect(localStorage.getItem('openburnbar.linux.wallpaper.v1')).toBe('auroraTeal');
    expect(document.documentElement.dataset.wallpaper).toBe('auroraTeal');
  });

  it('persists swarm speed and sparkle controls', () => {
    render(<SettingsAppearanceControls />);
    const speed = screen.getByRole('slider', { name: 'Swarm motion speed' });
    fireEvent.change(speed, { target: { value: '1.25' } });
    expect(JSON.parse(localStorage.getItem('openburnbar.linux.swarm.v1') ?? '{}')).toMatchObject({ speed: 1.25 });

    const sparkles = screen.getByRole('checkbox', { name: 'Enable swarm sparkles' });
    fireEvent.click(sparkles);
    expect(JSON.parse(localStorage.getItem('openburnbar.linux.swarm.v1') ?? '{}')).toMatchObject({ sparkles: true });
  });

  it('persists swarm shape and provider glyph selections', () => {
    render(<SettingsAppearanceControls />);

    const brandShapes = screen.getByRole('checkbox', { name: 'Include brand shapes in swarm cycle' });
    fireEvent.click(brandShapes);
    expect(JSON.parse(localStorage.getItem('openburnbar.linux.swarm.v1') ?? '{}')).toMatchObject({
      excludeBrandShapes: false
    });

    fireEvent.click(screen.getByRole('checkbox', { name: 'Click backdrop to cycle swarm shapes' }));
    expect(JSON.parse(localStorage.getItem('openburnbar.linux.swarm.v1') ?? '{}')).toMatchObject({
      allowsClickCycle: true
    });

    const claude = screen.getByRole('checkbox', { name: 'Show Claude Code glyph' });
    expect((claude as HTMLInputElement).checked).toBe(true);
    fireEvent.click(claude);
    expect(JSON.parse(localStorage.getItem('openburnbar.linux.swarm.v1') ?? '{}').providerGlyphs).not.toContain('claudecode');

    fireEvent.click(screen.getByRole('button', { name: 'None' }));
    expect(JSON.parse(localStorage.getItem('openburnbar.linux.swarm.v1') ?? '{}').providerGlyphs).toEqual([]);
  });
});
