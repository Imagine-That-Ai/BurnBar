// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { BackdropEngine } from '@openburnbar/gl-engine/engine/BackdropEngine';
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
const originalDocumentHidden = Object.getOwnPropertyDescriptor(document, 'hidden');
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
        } else if (property === 'getImageData') {
          object[property] = () => ({ data: new Uint8ClampedArray(400 * 400 * 4) });
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
  if (originalDocumentHidden) {
    Object.defineProperty(document, 'hidden', originalDocumentHidden);
  }
  if (originalVitestFlag === undefined) {
    delete process.env.VITEST;
  } else {
    process.env.VITEST = originalVitestFlag;
  }
});

describe('KernelBackdrop Linux capability fallback', () => {
  it('paints the Linux default 2D kernel during init without waiting on a chunk', () => {
    // Swarm Ember groups particles through Path2D. WebKitGTK exposes this API;
    // jsdom does not, so provide the smallest shape-compatible test double.
    vi.stubGlobal(
      'Path2D',
      class {
        arc(): void {}
      }
    );
    process.env.VITEST = '';
    const view = render(<KernelBackdrop skin={'editorial' satisfies ShellSkin} kernelId="swarmEmber" />);
    const backdrop = view.container.querySelector<HTMLElement>('.kernel-backdrop');
    expect(backdrop?.dataset.kernelRequested).toBe('swarmEmber');
    expect(backdrop?.dataset.kernelResolved).toBe('swarmEmber');
    expect(backdrop?.dataset.kernelResolution).toBe('native');
    expect(backdrop?.dataset.kernelSubstrate).toBe('2d');
    expect(backdrop?.dataset.glSupported).toBe('0');
    expect(contextCalls.filter((method) => method === 'fillRect').length).toBeGreaterThan(0);

    const paintsAfterInit = contextCalls.filter((method) => method === 'fillRect').length;
    pumpAnimationFrame(16);
    expect(contextCalls.filter((method) => method === 'fillRect').length).toBeGreaterThan(paintsAfterInit);
  });

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

  it('reveals the 2D fallback immediately when a WebGL2 context disappears mid-switch', () => {
    const context = makeCanvasContext();
    let probing = true;
    Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
      configurable: true,
      value(type: string) {
        if (type === 'webgl2') {
          // The capability probe succeeds, but the next canvas cannot acquire
          // a context: this models a suspended WebKit/VM compositor.
          if (probing) {
            probing = false;
            return { getExtension: () => null };
          }
          return null;
        }
        return context;
      }
    });

    const host = document.createElement('div');
    document.body.appendChild(host);
    const statuses: string[] = [];
    const engine = new BackdropEngine(host, {
      theme: 'dark',
      initialKernel: 'constellation',
      onStatus: (status) => statuses.push(status.reason)
    });

    expect(engine.glSupported).toBe(true);
    engine.setKernel('aurora');

    const canvases = [...host.querySelectorAll('canvas')];
    expect(canvases).toHaveLength(2);
    expect(statuses.at(-1)).toBe('context-unavailable');
    expect(canvases.at(-1)?.getAttribute('aria-hidden')).toBe('true');
    // The fallback cannot wait for the next rAF: hidden/backgrounded windows
    // may throttle that callback indefinitely.
    expect(canvases.at(-1)?.style.opacity).toBe('1');

    engine.destroy();
    host.remove();
  });

  it('falls back immediately on background context loss and retries the requested shader on resume', () => {
    const context = makeCanvasContext();
    const webgl = { getExtension: () => null } as unknown as WebGL2RenderingContext;
    let contextAvailable = true;
    Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
      configurable: true,
      value(type: string) {
        if (type === 'webgl2') return contextAvailable ? webgl : null;
        return context;
      }
    });

    const host = document.createElement('div');
    document.body.appendChild(host);
    const statuses: string[] = [];
    const engine = new BackdropEngine(host, {
      theme: 'dark',
      initialKernel: 'constellation',
      onStatus: (status) => statuses.push(status.reason)
    });

    engine.setKernel('aurora');
    const shaderCanvas = host.querySelectorAll('canvas').item(1);
    expect(shaderCanvas).not.toBeNull();
    expect(engine.getResolvedKernel()).toBe('aurora');

    // Model WebKitGTK losing its context while the window is backgrounded.
    // The host must not wait for a throttled rAF to reveal the safe fallback.
    contextAvailable = false;
    shaderCanvas?.dispatchEvent(new Event('webglcontextlost', { cancelable: true }));
    const fallbackCanvas = host.querySelectorAll('canvas').item(1);
    expect(engine.getResolvedKernel()).toBe('constellation');
    expect(statuses.at(-1)).toBe('context-unavailable');
    expect(fallbackCanvas?.style.opacity).toBe('1');
    expect(host.querySelectorAll('canvas')).toHaveLength(2);

    // Once the compositor presents the window again, reacquire the user's
    // requested shader instead of leaving the 2D recovery world installed.
    Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    document.dispatchEvent(new Event('visibilitychange'));
    contextAvailable = true;
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    document.dispatchEvent(new Event('visibilitychange'));
    expect(engine.getResolvedKernel()).toBe('aurora');
    expect(host.querySelectorAll('canvas')).toHaveLength(2);

    engine.destroy();
    host.remove();
  });
});
