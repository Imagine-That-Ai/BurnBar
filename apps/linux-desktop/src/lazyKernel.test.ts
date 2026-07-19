// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';
import { lazyKernel } from '@openburnbar/gl-engine/engine/lazyKernel';
import type {
  Kernel,
  KernelFactory,
  KernelFrameContext,
  KernelId,
  KernelPalette,
} from '@openburnbar/gl-engine/engine/types';

const PALETTE: KernelPalette = {
  theme: 'dark',
  bg: [7, 8, 15],
  accents: [[131, 142, 255]],
  ink: [232, 236, 255],
  intensity: 1
};

function frame(overrides: Partial<KernelFrameContext> = {}): KernelFrameContext {
  return {
    width: 320,
    height: 180,
    dpr: 2,
    theme: 'dark',
    palette: PALETTE,
    reducedMotion: false,
    ...overrides
  };
}

interface Mock2D {
  fills: Array<{ style: string; width: number; height: number }>;
  transforms: number[][];
  context: CanvasRenderingContext2D;
}

function mock2d(): Mock2D {
  let fillStyle = '';
  const fills: Mock2D['fills'] = [];
  const transforms: number[][] = [];
  const context = {
    setTransform(...values: number[]) {
      transforms.push(values);
    },
    fillRect(_x: number, _y: number, width: number, height: number) {
      fills.push({ style: fillStyle, width, height });
    },
    get fillStyle() {
      return fillStyle;
    },
    set fillStyle(value: string) {
      fillStyle = value;
    }
  } as unknown as CanvasRenderingContext2D;
  return { fills, transforms, context };
}

function mockKernel(id: KernelId, substrate: Kernel['substrate']): Kernel & {
  init: ReturnType<typeof vi.fn>;
  renderStatic: ReturnType<typeof vi.fn>;
} {
  return {
    id,
    label: id,
    substrate,
    init: vi.fn(),
    frame: vi.fn(),
    resize: vi.fn(),
    setTheme: vi.fn(),
    renderStatic: vi.fn(),
    dispose: vi.fn()
  } as unknown as Kernel & {
    init: ReturnType<typeof vi.fn>;
    renderStatic: ReturnType<typeof vi.fn>;
  };
}

async function flushImport(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: unknown) => void;
} {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('lazyKernel loading boundary', () => {
  it('paints an opaque 2D base before import resolution and hands off the latest resize frame', async () => {
    const canvas = mock2d();
    const load = deferred<KernelFactory>();
    const real = mockKernel('flow', '2d');
    const kernel = lazyKernel('flow', 'Flow Field', '2d', () => load.promise);
    const first = frame();
    const resized = frame({ width: 640, height: 360, dpr: 1 });

    kernel.init(canvas.context, first);

    expect(canvas.fills).toEqual([{ style: 'rgb(7,8,15)', width: 320, height: 180 }]);
    expect(canvas.transforms).toEqual([[2, 0, 0, 2, 0, 0]]);

    kernel.resize(resized);
    expect(canvas.fills.at(-1)).toEqual({ style: 'rgb(7,8,15)', width: 640, height: 360 });
    expect(canvas.transforms.at(-1)).toEqual([1, 0, 0, 1, 0, 0]);

    load.resolve(() => real);
    await flushImport();

    expect(real.init).toHaveBeenCalledOnce();
    expect(real.init).toHaveBeenCalledWith(canvas.context, resized);
  });

  it('replays reduced-motion static rendering after the lazy handoff', async () => {
    const canvas = mock2d();
    const load = deferred<KernelFactory>();
    const real = mockKernel('boids', '2d');
    const kernel = lazyKernel('boids', 'Boids', '2d', () => load.promise);

    kernel.init(canvas.context, frame({ reducedMotion: true }));
    kernel.renderStatic?.();
    expect(real.renderStatic).not.toHaveBeenCalled();

    load.resolve(() => real);
    await flushImport();

    expect(real.init).toHaveBeenCalledOnce();
    expect(real.renderStatic).toHaveBeenCalledOnce();
  });

  it('does not paint a 2D placeholder for shader-backed kernels', async () => {
    const canvas = mock2d();
    const gl = {} as WebGL2RenderingContext;
    const load = deferred<KernelFactory>();
    const real = mockKernel('aurora', 'webgl2');
    const kernel = lazyKernel('aurora', 'Aurora', 'webgl2', () => load.promise);
    const initial = frame();

    kernel.init(gl, initial);

    expect(canvas.fills).toHaveLength(0);
    expect(canvas.transforms).toHaveLength(0);

    load.resolve(() => real);
    await flushImport();

    expect(real.init).toHaveBeenCalledWith(gl, initial);
  });

  it('absorbs a rejected chunk load so the painted 2D base remains usable', async () => {
    const canvas = mock2d();
    const load = deferred<KernelFactory>();
    const kernel = lazyKernel('flow', 'Flow Field', '2d', () => load.promise);

    kernel.init(canvas.context, frame());
    load.reject(new Error('offline chunk'));
    await expect(flushImport()).resolves.toBeUndefined();

    kernel.resize(frame({ width: 400, height: 200, dpr: 1 }));
    expect(canvas.fills.at(-1)).toEqual({ style: 'rgb(7,8,15)', width: 400, height: 200 });
  });
});
