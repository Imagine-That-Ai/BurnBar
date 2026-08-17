import { webcrypto } from 'node:crypto';

import { afterEach, beforeEach, vi } from 'vitest';

Object.defineProperty(globalThis, 'crypto', {
  configurable: true,
  value: webcrypto
});

if (typeof globalThis.PointerEvent === 'undefined') {
  Object.defineProperty(globalThis, 'PointerEvent', {
    configurable: true,
    value: MouseEvent
  });
}

/* jsdom ships no ResizeObserver. The popup measures its composer with one, so
   stub it rather than letting the path throw: observation is recorded and the
   callback can be fired on demand. */
if (typeof globalThis.ResizeObserver === 'undefined') {
  class TestResizeObserver implements ResizeObserver {
    private readonly observed = new Set<Element>();

    constructor(private readonly callback: ResizeObserverCallback) {}

    observe(target: Element): void {
      this.observed.add(target);
    }

    unobserve(target: Element): void {
      this.observed.delete(target);
    }

    disconnect(): void {
      this.observed.clear();
    }

    emit(blockSize: number): void {
      for (const target of this.observed) {
        this.callback(
          [{ target, borderBoxSize: [{ blockSize, inlineSize: 0 }] } as unknown as ResizeObserverEntry],
          this
        );
      }
    }
  }
  Object.defineProperty(globalThis, 'ResizeObserver', {
    configurable: true,
    value: TestResizeObserver
  });
}

/* jsdom ships no ResizeObserver. The popup measures its composer with one, so
   stub it rather than skipping the path: observation is recorded, and the
   callback fires on demand for tests that care about the measurement. */
if (typeof globalThis.ResizeObserver === 'undefined') {
  class TestResizeObserver implements ResizeObserver {
    static instances: TestResizeObserver[] = [];
    readonly observed = new Set<Element>();

    constructor(private readonly callback: ResizeObserverCallback) {
      TestResizeObserver.instances.push(this);
    }

    observe(target: Element): void {
      this.observed.add(target);
    }

    unobserve(target: Element): void {
      this.observed.delete(target);
    }

    disconnect(): void {
      this.observed.clear();
    }

    emit(blockSize: number): void {
      for (const target of this.observed) {
        this.callback(
          [{ target, borderBoxSize: [{ blockSize, inlineSize: 0 }] } as unknown as ResizeObserverEntry],
          this
        );
      }
    }
  }
  Object.defineProperty(globalThis, 'ResizeObserver', {
    configurable: true,
    value: TestResizeObserver
  });
}

beforeEach(() => {
  document.documentElement.removeAttribute('data-openburnbar-page-world');
  document.head.replaceChildren();
  document.body.replaceChildren();
  Object.defineProperty(window, 'visualViewport', {
    configurable: true,
    value: {
      width: 1024,
      height: 768,
      offsetLeft: 0,
      offsetTop: 0,
      scale: 1
    }
  });
  Object.defineProperty(window, 'innerWidth', { configurable: true, value: 1024 });
  Object.defineProperty(window, 'innerHeight', { configurable: true, value: 768 });
  Object.defineProperty(window, 'scrollX', { configurable: true, writable: true, value: 0 });
  Object.defineProperty(window, 'scrollY', { configurable: true, writable: true, value: 0 });
  Object.defineProperty(window, 'devicePixelRatio', { configurable: true, value: 2 });
  window.requestAnimationFrame = (callback: FrameRequestCallback): number => {
    callback(performance.now());
    return 1;
  };
  window.cancelAnimationFrame = vi.fn();
  window.scrollTo = vi.fn((optionsOrX?: ScrollToOptions | number, y?: number) => {
    const x = typeof optionsOrX === 'number' ? optionsOrX : typeof optionsOrX?.left === 'number' ? optionsOrX.left : 0;
    const nextY = typeof optionsOrX === 'number' ? (y ?? 0) : typeof optionsOrX?.top === 'number' ? optionsOrX.top : 0;
    window.scrollX = x;
    window.scrollY = nextY;
  });
  window.scrollBy = vi.fn((optionsOrX?: ScrollToOptions | number, y?: number) => {
    const x = typeof optionsOrX === 'number' ? optionsOrX : typeof optionsOrX?.left === 'number' ? optionsOrX.left : 0;
    const nextY = typeof optionsOrX === 'number' ? (y ?? 0) : typeof optionsOrX?.top === 'number' ? optionsOrX.top : 0;
    window.scrollX += x;
    window.scrollY += nextY;
  });
  Element.prototype.scrollIntoView = vi.fn();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
