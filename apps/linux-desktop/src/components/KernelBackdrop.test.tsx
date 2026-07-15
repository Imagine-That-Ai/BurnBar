// @vitest-environment jsdom
import { cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { KernelBackdrop } from './KernelBackdrop.js';
import { fallbackProfileForSkin } from '../lib/adaptiveForeground.js';

describe('KernelBackdrop readability bridge', () => {
  afterEach(cleanup);

  it('publishes deterministic fallback profiles and updates them on skin changes', async () => {
    const onReadability = vi.fn();
    const view = render(
      <KernelBackdrop skin="editorial" kernelId="mesh" onReadability={onReadability} />
    );

    await waitFor(() => {
      expect(onReadability).toHaveBeenLastCalledWith(fallbackProfileForSkin('editorial'));
    });
    expect(view.container.firstElementChild?.getAttribute('data-backdrop-mode')).toBe('css');

    view.rerender(
      <KernelBackdrop skin="aurora" kernelId="aurora" onReadability={onReadability} />
    );
    await waitFor(() => {
      expect(onReadability).toHaveBeenLastCalledWith(fallbackProfileForSkin('aurora'));
    });
    expect(view.container.firstElementChild?.getAttribute('data-kernel')).toBe('aurora');
  });

  it('stops publishing after teardown', async () => {
    const onReadability = vi.fn();
    const view = render(
      <KernelBackdrop skin="editorial" kernelId="mesh" onReadability={onReadability} />
    );
    await waitFor(() => expect(onReadability).toHaveBeenCalled());
    view.unmount();
    const count = onReadability.mock.calls.length;
    window.dispatchEvent(new Event('resize'));
    document.dispatchEvent(new Event('visibilitychange'));
    expect(onReadability).toHaveBeenCalledTimes(count);
  });
});
