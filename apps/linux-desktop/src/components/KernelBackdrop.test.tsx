// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ShellSkin } from '../state/shellStore.js';
import { KernelBackdrop } from './KernelBackdrop.js';

type RafCallback = (time: number) => void;

const originalCanvasGetContext = Object.getOwnPropertyDescriptor(
  HTMLCanvasElement.prototype,
  'getContext'
);
const originalElementRect = Object.getOwnPropertyDescriptor(
  HTMLElement.prototype,
  'getBoundingClientRect'
);
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, 'matchMedia');
const originalVitestFlag = process.env.VITEST;

let rafQueue: RafCallback[] = [];
let contextCalls: string[] = [];

function makeCanvasContext(): CanvasRenderingContext2D {
  const target: Record<string, unknown> = {};
  return new Proxy(target, {
    get(object, property: string | symbol) {
      if (typeof property !== 'string') return undefined;
      if (!(property in object)) {
        if (property === 'createRadialGradient') {
          object[property] = () => ({ addColorStop: () => undefined });
        } else {
          object[property] = (..._args: unknown[]) => {
            contextCalls.push(property);
          };
        }
      }
      return object[property];
    }
  }) as unknown as CanvasRenderingContext2D;
}

function pumpAnimationFrame(time: number): void {
  const callbacks = rafQueue.splice(0);
  callbacks.forEach((callback) => callback(time));
}

beforeEach(() => {
  contextCalls = [];
  rafQueue = [];

  // The VM's WebKitGTK path exposes a WebGL2 function but cannot create a
  // context. Returning null here exercises that exact capability boundary.
  const context = makeCanvasContext();
  Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
    configurable: true,
    value(type: string) {
      return type === 'webgl2' || type === 'webgpu' ? null : context;
    }
  });
  Object.defineProperty(HTMLElement.prototype, 'getBoundingClientRect', {
    configurable: true,
    value() {
      return {
        width: 320,
        height: 200,
        top: 0,
        right: 320,
        bottom: 200,
        left: 0,
        x: 0,
        y: 0,
        toJSON: () => ({})
      };
    }
  });

  vi.stubGlobal('requestAnimationFrame', (callback: RafCallback) => {
    rafQueue.push(callback);
    return rafQueue.length;
  });
  vi.stubGlobal('cancelAnimationFrame', () => undefined);
  vi.stubGlobal(
    'ResizeObserver',
    class {
      observe(): void {}
      disconnect(): void {}
    }
  );
  vi.stubGlobal(
    'IntersectionObserver',
    class {
      observe(): void {}
      disconnect(): void {}
    }
  );
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    value: () => ({
      matches: false,
      addEventListener: () => undefined,
      removeEventListener: () => undefined
    })
  });
});

afterEach(() => {
  cleanup();
  rafQueue = [];
  vi.unstubAllGlobals();
  if (originalCanvasGetContext) {
    Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', originalCanvasGetContext);
  }
  if (originalElementRect) {
    Object.defineProperty(HTMLElement.prototype, 'getBoundingClientRect', originalElementRect);
  }
  if (originalMatchMedia) {
    Object.defineProperty(window, 'matchMedia', originalMatchMedia);
  } else {
    delete (window as Partial<Window>).matchMedia;
  }
  if (originalVitestFlag === undefined) {
    delete process.env.VITEST;
  } else {
    process.env.VITEST = originalVitestFlag;
  }
});

describe('KernelBackdrop Linux capability fallback', () => {
  it('publishes a truthful 2D receipt and keeps the fallback animated', () => {
    // KernelBackdrop intentionally avoids constructing a rendering engine in
    // ordinary Vitest tests. Temporarily opt into the real host lifecycle for
    // this capability-boundary regression test.
    process.env.VITEST = '';
    const view = render(<KernelBackdrop skin={'editorial' satisfies ShellSkin} kernelId="aurora" />);
    const backdrop = view.container.querySelector<HTMLElement>('.kernel-backdrop');
    expect(backdrop).not.toBeNull();
    expect(backdrop?.dataset.kernelRequested).toBe('aurora');
    expect(backdrop?.dataset.kernelResolved).toBe('constellation');
    expect(backdrop?.dataset.kernelResolution).toBe('webgl2-unavailable');
    expect(backdrop?.dataset.kernelFallback).toBe('1');
    expect(backdrop?.dataset.kernelSubstrate).toBe('2d');
    expect(backdrop?.dataset.glSupported).toBe('0');

    const canvas = backdrop?.querySelector('canvas');
    expect(canvas).not.toBeNull();
    expect(canvas?.getAttribute('aria-hidden')).toBe('true');
    expect(canvas?.style.opacity).toBe('1');

    const paintsAfterInit = contextCalls.filter((method) => method === 'fillRect').length;
    pumpAnimationFrame(16); // deferred obstacle harvest + first render loop
    pumpAnimationFrame(32); // second render loop
    const paintsAfterFrames = contextCalls.filter((method) => method === 'fillRect').length;
    expect(paintsAfterFrames).toBeGreaterThan(paintsAfterInit);
  });
});
