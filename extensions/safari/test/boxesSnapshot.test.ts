import {
  boxAnnotation,
  cssPixelsToDevicePixels,
  isBoxInViewport,
  rectToBoundingBox,
  roundCoordinate,
  viewportInfo
} from '../src/content/boxes';
import { selectorForElement, SnapshotRegistry } from '../src/content/snapshot';

function rect(left: number, top: number, width: number, height: number): DOMRect {
  return {
    x: left,
    y: top,
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height,
    toJSON: () => ({})
  } as DOMRect;
}

describe('box and snapshot utilities', () => {
  it('maps viewport CSS coordinates with visual viewport offsets', () => {
    expect(
      rectToBoundingBox(rect(10.126, 20.994, 100.555, 42.222), {
        offsetLeft: 3.25,
        offsetTop: 4.5
      } as VisualViewport)
    ).toEqual({
      x: 13.38,
      y: 25.49,
      width: 100.56,
      height: 42.22
    });
    expect(boxAnnotation({ x: 1, y: 2, width: 3, height: 4 })).toBe('[box=1,2,3,4]');
    expect(roundCoordinate(Number.NaN)).toBe(0);
    expect(cssPixelsToDevicePixels(12.5, 2)).toBe(25);
    expect(isBoxInViewport({ x: -5, y: 2, width: 10, height: 10 }, { width: 100, height: 100 })).toBe(true);
    expect(isBoxInViewport({ x: 101, y: 2, width: 10, height: 10 }, { width: 100, height: 100 })).toBe(false);
  });

  it('fails closed for degenerate boxes and falls back when viewport metadata is absent', () => {
    expect(rectToBoundingBox(rect(1, 2, -3, -4), null)).toEqual({
      x: 1,
      y: 2,
      width: 0,
      height: 0
    });
    expect(cssPixelsToDevicePixels(10, Number.NaN)).toBe(1);
    expect(isBoxInViewport({ x: 0, y: 0, width: 0, height: 10 }, { width: 100, height: 100 })).toBe(false);
    expect(isBoxInViewport({ x: 0, y: 0, width: 10, height: 0 }, { width: 100, height: 100 })).toBe(false);
    expect(isBoxInViewport({ x: 100, y: 0, width: 10, height: 10 }, { width: 100, height: 100 })).toBe(false);
    expect(isBoxInViewport({ x: 0, y: 100, width: 10, height: 10 }, { width: 100, height: 100 })).toBe(false);
    expect(isBoxInViewport({ x: -10, y: 0, width: 10, height: 10 }, { width: 100, height: 100 })).toBe(false);
    expect(isBoxInViewport({ x: 0, y: -10, width: 10, height: 10 }, { width: 100, height: 100 })).toBe(false);

    const documentValue = {
      documentElement: {
        scrollWidth: 900,
        clientWidth: 800,
        scrollHeight: 1200,
        clientHeight: 700
      },
      body: null
    } as unknown as Document;
    const windowValue = {
      visualViewport: null,
      innerWidth: undefined,
      innerHeight: undefined,
      scrollX: Number.NaN,
      scrollY: Number.NaN,
      devicePixelRatio: 0
    } as unknown as Window;
    expect(viewportInfo(documentValue, windowValue)).toEqual({
      width: 800,
      height: 700,
      scrollX: 0,
      scrollY: 0,
      pageWidth: 900,
      pageHeight: 1200,
      devicePixelRatio: 1,
      visualViewportOffsetLeft: 0,
      visualViewportOffsetTop: 0,
      visualViewportScale: 1
    });
  });

  it('reports page and visual viewport geometry', () => {
    Object.defineProperty(document.documentElement, 'scrollWidth', { configurable: true, value: 1400 });
    Object.defineProperty(document.documentElement, 'scrollHeight', { configurable: true, value: 2400 });
    Object.defineProperty(document.documentElement, 'clientWidth', { configurable: true, value: 1000 });
    Object.defineProperty(document.documentElement, 'clientHeight', { configurable: true, value: 700 });
    window.scrollX = 20;
    window.scrollY = 80;
    const result = viewportInfo();
    expect(result).toMatchObject({
      width: 1024,
      height: 768,
      scrollX: 20,
      scrollY: 80,
      pageWidth: 1400,
      pageHeight: 2400,
      devicePixelRatio: 2
    });
  });

  it('creates stable selectors and resolves refs, selectors, and points', () => {
    document.body.innerHTML = `
      <main>
        <button id="buy">Buy</button>
        <div><button data-testid="save">Save</button><button>Other</button></div>
      </main>
    `;
    const buy = document.getElementById('buy')!;
    const save = document.querySelector('[data-testid="save"]')!;
    const other = document.querySelector('div button:nth-of-type(2)')!;
    expect(selectorForElement(buy)).toBe('#buy');
    expect(selectorForElement(save)).toContain('[data-testid="save"]');
    expect(selectorForElement(other)).toContain(':nth-of-type(2)');

    const registry = new SnapshotRegistry();
    const ref = registry.register(buy);
    expect(registry.resolve({ ref })).toBe(buy);
    expect(registry.resolve({ selector: '#buy' })).toBe(buy);
    Object.defineProperty(document, 'elementFromPoint', {
      configurable: true,
      value: vi.fn()
    });
    vi.spyOn(document, 'elementFromPoint').mockReturnValue(save);
    expect(registry.resolve({ point: { x: 2, y: 4 } })).toBe(save);

    buy.remove();
    expect(() => registry.resolve({ ref })).toThrow(/stale/u);
    expect(() => registry.resolve({ selector: '[' })).toThrow(/invalid/u);
    expect(() => registry.resolve({ selector: '.missing' })).toThrow(/No element/u);
    vi.spyOn(document, 'elementFromPoint').mockReturnValue(null);
    expect(() => registry.resolve({ point: { x: 20, y: 20 } })).toThrow(/No element/u);
    expect(() => registry.resolve({})).toThrow(/did not specify/u);
    registry.reset();
  });
});
