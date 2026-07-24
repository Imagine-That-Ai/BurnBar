// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { SurfaceErrorBoundary } from './SurfaceErrorBoundary.js';

afterEach(cleanup);

function ThrowingSurface({ shouldThrow }: { shouldThrow: boolean }) {
  if (shouldThrow) throw new Error('provider payload is malformed');
  return <p>Recovered route body</p>;
}

describe('SurfaceErrorBoundary', () => {
  it('keeps a render failure actionable without exposing the exception text', () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      render(
        <SurfaceErrorBoundary label="Chat / Hermes" repairRoute="support" onRepair={vi.fn()}>
          <ThrowingSurface shouldThrow />
        </SurfaceErrorBoundary>
      );

      const alert = screen.getByRole('alert');
      expect(alert.textContent).toContain('Chat / Hermes could not be rendered');
      expect(alert.textContent).toContain('Retry Chat / Hermes');
      expect(alert.textContent).toContain('Open Support');
      expect(alert.textContent).not.toContain('provider payload is malformed');
      expect(errorSpy).toHaveBeenCalledWith(
        'linux_surface_render_failed',
        expect.objectContaining({ message: 'provider payload is malformed' })
      );
    } finally {
      errorSpy.mockRestore();
    }
  });

  it('remounts the route body after Retry', () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    let shouldThrow = true;
    try {
      const view = render(
        <SurfaceErrorBoundary label="Overview" repairRoute="support" onRepair={vi.fn()}>
          <ThrowingSurface shouldThrow={shouldThrow} />
        </SurfaceErrorBoundary>
      );
      shouldThrow = false;
      view.rerender(
        <SurfaceErrorBoundary label="Overview" repairRoute="support" onRepair={vi.fn()}>
          <ThrowingSurface shouldThrow={shouldThrow} />
        </SurfaceErrorBoundary>
      );
      fireEvent.click(screen.getByRole('button', { name: 'Retry Overview' }));
      expect(screen.getByText('Recovered route body')).toBeTruthy();
    } finally {
      errorSpy.mockRestore();
    }
  });

  it('routes recovery to Support when the route cannot be retried', () => {
    const onRepair = vi.fn();
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      render(
        <SurfaceErrorBoundary label="Projects" repairRoute="support" onRepair={onRepair}>
          <ThrowingSurface shouldThrow />
        </SurfaceErrorBoundary>
      );
      fireEvent.click(screen.getByRole('button', { name: 'Open Support' }));
      expect(onRepair).toHaveBeenCalledOnce();
    } finally {
      errorSpy.mockRestore();
    }
  });
});
