// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import type { KernelResolution } from '@openburnbar/gl-engine/engine/types';
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
});
