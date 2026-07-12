import { afterEach, describe, expect, it, vi } from 'vitest';
import { clearPerfSamples, listPerfSamples, markAfterPaint } from './perfMarks.js';

describe('performance marks', () => {
  afterEach(() => {
    clearPerfSamples();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('records route completion only after two animation frames', () => {
    const frames: FrameRequestCallback[] = [];
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => {
      frames.push(callback);
      return frames.length;
    });
    const now = vi.spyOn(performance, 'now');
    now.mockReturnValueOnce(10).mockReturnValueOnce(26);

    markAfterPaint('route.navigation', 'test-after-paint');
    expect(listPerfSamples()).toEqual([]);
    frames.shift()?.(16);
    expect(listPerfSamples()).toEqual([]);
    frames.shift()?.(24);

    expect(listPerfSamples()).toMatchObject([
      { name: 'route.navigation', ms: 16, source: 'test-after-paint' }
    ]);
  });
});
