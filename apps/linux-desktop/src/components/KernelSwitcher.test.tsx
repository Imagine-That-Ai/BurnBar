// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { KernelResolution } from '@openburnbar/gl-engine/engine/types';
import { KERNEL_META } from '@openburnbar/gl-engine/engine/registry';
import { KERNEL_RESOLUTION_EVENT } from './KernelBackdrop.js';
import { KernelSwitcher } from './KernelSwitcher.js';

afterEach(() => {
  cleanup();
  localStorage.clear();
});

describe('KernelSwitcher capability status', () => {
  it('labels a requested WebGL2 kernel when the live backdrop uses 2D fallback', () => {
    render(<KernelSwitcher kernelId="aurora" onKernelChange={() => {}} />);

    const status: KernelResolution = {
      requestedId: 'aurora',
      resolvedId: 'constellation',
      requestedSubstrate: 'webgl2',
      resolvedSubstrate: '2d',
      reason: 'webgl2-unavailable',
      fallback: true,
      glSupported: false
    };
    fireEvent(
      window,
      new CustomEvent<KernelResolution>(KERNEL_RESOLUTION_EVENT, { detail: status })
    );

    const trigger = screen.getByRole('button', { name: /Aurora.*2D fallback/ });
    expect(trigger.getAttribute('title')).toContain('WebGL2 unavailable');
  });

  it('does not label a native WebGL2 render as degraded', () => {
    render(<KernelSwitcher kernelId="aurora" onKernelChange={() => {}} />);
    const status: KernelResolution = {
      requestedId: 'aurora',
      resolvedId: 'aurora',
      requestedSubstrate: 'webgl2',
      resolvedSubstrate: 'webgl2',
      reason: 'native',
      fallback: false,
      glSupported: true
    };
    fireEvent(
      window,
      new CustomEvent<KernelResolution>(KERNEL_RESOLUTION_EVENT, { detail: status })
    );

    expect(screen.getByRole('button', { name: 'Aurora' })).toBeTruthy();
  });

  it('supports arrow-key listbox navigation and activation', () => {
    const onKernelChange = vi.fn();
    render(<KernelSwitcher kernelId="aurora" onKernelChange={onKernelChange} />);
    const trigger = screen.getByRole('button', { name: 'Aurora' });

    fireEvent.keyDown(trigger, { key: 'ArrowDown' });
    expect(trigger.getAttribute('aria-expanded')).toBe('true');
    const options = screen.getAllByRole('option');
    const selectedIndex = KERNEL_META.findIndex((kernel) => kernel.id === 'aurora');
    expect(document.activeElement).toBe(options[selectedIndex]);

    fireEvent.keyDown(options[selectedIndex], { key: 'ArrowDown' });
    const nextIndex = (selectedIndex + 1) % options.length;
    expect(document.activeElement).toBe(options[nextIndex]);
    fireEvent.keyDown(options[nextIndex], { key: 'Enter' });
    expect(onKernelChange).toHaveBeenCalledWith(KERNEL_META[nextIndex].id);
    expect(document.activeElement).toBe(trigger);
  });

  it('supports Home, End, and Escape without trapping focus', () => {
    render(<KernelSwitcher kernelId="aurora" onKernelChange={() => {}} />);
    const trigger = screen.getByRole('button', { name: 'Aurora' });
    fireEvent.click(trigger);
    const options = screen.getAllByRole('option');

    fireEvent.keyDown(options[0], { key: 'End' });
    expect(document.activeElement).toBe(options[options.length - 1]);
    fireEvent.keyDown(options[options.length - 1], { key: 'Home' });
    expect(document.activeElement).toBe(options[0]);
    fireEvent.keyDown(options[0], { key: 'Escape' });
    expect(trigger.getAttribute('aria-expanded')).toBe('false');
    expect(document.activeElement).toBe(trigger);
  });
});
