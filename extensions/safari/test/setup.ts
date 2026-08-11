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
