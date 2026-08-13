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
}

function installCanvasHarness(open: boolean): CanvasHarness {
  const root = document.createElement('div');
  root.innerHTML = `
    <section id="mode-popover" ${open ? '' : 'hidden'}>
      <div class="mode-track">
        <canvas class="mode-fire"></canvas>
        <canvas class="mode-knob"></canvas>
      </div>
    </section>
  `;
  document.body.append(root);
  const fire = root.querySelector<HTMLCanvasElement>('.mode-fire');
  const knob = root.querySelector<HTMLCanvasElement>('.mode-knob');
  if (!fire || !knob) {
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
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(context as unknown as CanvasRenderingContext2D);
  return { context, root, fire, knob };
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
});
