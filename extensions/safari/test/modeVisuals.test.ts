import { beforeEach, describe, expect, it, vi } from 'vitest';

interface CanvasHarness {
  context: {
    createImageData: ReturnType<typeof vi.fn>;
    drawImage: ReturnType<typeof vi.fn>;
    getImageData: ReturnType<typeof vi.fn>;
    putImageData: ReturnType<typeof vi.fn>;
  };
  root: HTMLElement;
  fire: HTMLCanvasElement;
  knob: HTMLCanvasElement;
  fallback: HTMLImageElement;
}

function installCanvasHarness(open: boolean): CanvasHarness {
  const root = document.createElement('div');
  root.innerHTML = `
    <section id="mode-popover" ${open ? '' : 'hidden'}>
      <div class="mode-track">
        <canvas class="mode-fire"></canvas>
        <img class="mode-knob-fallback" src="icons/app-logo.svg" alt="" aria-hidden="true">
        <canvas class="mode-knob"></canvas>
      </div>
    </section>
  `;
  document.body.append(root);
  const fire = root.querySelector<HTMLCanvasElement>('.mode-fire');
  const knob = root.querySelector<HTMLCanvasElement>('.mode-knob');
  const fallback = root.querySelector<HTMLImageElement>('.mode-knob-fallback');
  if (!fire || !knob || !fallback) {
    throw new Error('Mode visual canvases were not created.');
  }
  vi.spyOn(fire, 'getBoundingClientRect').mockReturnValue(new DOMRect(0, 0, 204, 26));
  vi.spyOn(knob, 'getBoundingClientRect').mockReturnValue(new DOMRect(0, 0, 50, 50));
  const context = {
    createImageData: vi.fn((width: number, height: number) => ({
      data: new Uint8ClampedArray(width * height * 4),
      height,
      width
    })),
    drawImage: vi.fn(),
    getImageData: vi.fn((_x: number, _y: number, width: number, height: number) => ({
      data: new Uint8ClampedArray(width * height * 4),
      height,
      width
    })),
    putImageData: vi.fn()
  };
  // The suite's beforeEach stubs the CanvasRenderingContext2D global, so a real
  // instance can carry the mocked drawing surface without any type assertion.
  const context2D = Object.assign(new CanvasRenderingContext2D(), context);
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(context2D);
  return { context, root, fire, knob, fallback };
}

describe('mode visuals', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.stubGlobal('CanvasRenderingContext2D', class CanvasRenderingContext2D {});
    Object.defineProperty(window, 'devicePixelRatio', { configurable: true, value: 2 });
    vi.stubGlobal(
      'matchMedia',
      vi.fn(() => ({
        matches: false,
        media: '(prefers-reduced-motion: reduce)',
        onchange: null,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        addListener: vi.fn(),
        removeListener: vi.fn(),
        dispatchEvent: vi.fn()
      }))
    );
  });

  it('does no canvas work while the popover is hidden', async () => {
    const harness = installCanvasHarness(false);
    const { initializeModeVisuals } = await import('../src/popup/modeVisuals');
    initializeModeVisuals(harness.root);
    expect(harness.context.createImageData).not.toHaveBeenCalled();
  });

  it('uses Retina backing stores and schedules live frames only while open', async () => {
    vi.useFakeTimers();
    const harness = installCanvasHarness(true);
    const { initializeModeVisuals } = await import('../src/popup/modeVisuals');
    initializeModeVisuals(harness.root);
    expect(harness.fire.width).toBe(408);
    expect(harness.fire.height).toBe(52);
    expect(harness.knob.width).toBe(100);
    expect(harness.knob.height).toBe(100);
    expect(vi.getTimerCount()).toBeGreaterThan(0);
    const popover = harness.root.querySelector<HTMLElement>('#mode-popover');
    if (!popover) {
      throw new Error('Mode popover was not created.');
    }
    popover.hidden = true;
    initializeModeVisuals(harness.root);
    expect(vi.getTimerCount()).toBe(0);
    vi.useRealTimers();
  });

  it('renders a static fire frame without animation when reduced motion is requested', async () => {
    vi.useFakeTimers();
    vi.mocked(window.matchMedia).mockReturnValue({
      matches: true,
      media: '(prefers-reduced-motion: reduce)',
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    });
    const harness = installCanvasHarness(true);
    const { initializeModeVisuals } = await import('../src/popup/modeVisuals');
    initializeModeVisuals(harness.root);
    expect(harness.context.putImageData).toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
    vi.useRealTimers();
  });

  it('pauses live timers while hidden and resumes pending visual loops when visible again', async () => {
    vi.useFakeTimers();
    let visibilityState: DocumentVisibilityState = 'visible';
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => visibilityState
    });
    const harness = installCanvasHarness(true);
    const { initializeModeVisuals } = await import('../src/popup/modeVisuals');
    initializeModeVisuals(harness.root);
    expect(vi.getTimerCount()).toBeGreaterThan(0);

    visibilityState = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    expect(vi.getTimerCount()).toBe(0);

    visibilityState = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    expect(vi.getTimerCount()).toBeGreaterThan(0);
    vi.useRealTimers();
  });

  it('keeps the image fallback visible when the knob canvas context is unavailable', async () => {
    const harness = installCanvasHarness(true);
    vi.spyOn(harness.knob, 'getContext').mockReturnValue(null);
    const { initializeModeVisuals } = await import('../src/popup/modeVisuals');
    initializeModeVisuals(harness.root);
    expect(harness.knob.dataset.rendered).toBeUndefined();
    expect(harness.fallback.hidden).toBe(false);
  });

  it('reveals the liquid-metal canvas only after its first successful paint', async () => {
    class FakeImage {
      onload: (() => void) | null = null;

      set src(_value: string) {
        this.onload?.();
      }
    }
    vi.stubGlobal('Image', FakeImage);
    const harness = installCanvasHarness(true);
    const { initializeModeVisuals } = await import('../src/popup/modeVisuals');
    initializeModeVisuals(harness.root);
    expect(harness.knob.dataset.rendered).toBe('true');
    expect(harness.fallback.hidden).toBe(true);
  });
});
