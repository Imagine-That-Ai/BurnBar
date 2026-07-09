import { useEffect, useRef, useState } from 'react';
import { BackdropEngine } from '@openburnbar/gl-engine/engine/BackdropEngine';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { resolveSkinPalette } from '../lib/resolveSkinPalette.js';
import {
  DASHBOARD_MOTION_SPEED_MULTIPLIER
} from '../state/kernelPrefs.js';
import type { ShellSkin } from '../state/shellStore.js';

/**
 * Real gl-engine kernel backdrop (Canvas2D / WebGL2 via BackdropEngine).
 *
 * On WebKitGTK + virt GPU, WebGL2 often needs `LIBGL_ALWAYS_SOFTWARE=1` in the
 * process environment. Without WebGL2, webgl2 kernels fall back to the default
 * 2d kernel inside the engine — still real kernels, not CSS washes.
 *
 * Escape hatch only: localStorage `openburnbar.linux.backdrop.mode.v1 = "css"`
 * forces the emergency CSS wash (not the product kernels).
 */
export function KernelBackdrop({
  skin,
  kernelId
}: {
  skin: ShellSkin;
  kernelId: KernelId;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const engineRef = useRef<BackdropEngine | null>(null);
  const requestedKernelRef = useRef(kernelId);
  requestedKernelRef.current = kernelId;
  const [resolvedId, setResolvedId] = useState<KernelId>(kernelId);
  const [glOk, setGlOk] = useState<boolean | null>(null);
  const [mode, setMode] = useState<'canvas' | 'css'>('canvas');

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    if (typeof process !== 'undefined' && process.env.VITEST) return;

    const forced =
      typeof localStorage !== 'undefined'
        ? localStorage.getItem('openburnbar.linux.backdrop.mode.v1')
        : null;
    if (forced === 'css') {
      setMode('css');
      container.dataset.backdropMode = 'css';
      return;
    }

    const probe = document.createElement('canvas');
    try {
      if (!probe.getContext('2d')) {
        setMode('css');
        container.dataset.backdropMode = 'css';
        return;
      }
    } catch {
      setMode('css');
      container.dataset.backdropMode = 'css';
      return;
    }

    // Always mount the real engine. Do not short-circuit to CSS for missing WebGL2 —
    // 2d kernels (constellation, flow, boids, swarmEmber) still run, and webgl2 kernels
    // resolve via engine fallbacks when GL is absent.
    setMode('canvas');
    container.dataset.backdropMode = 'canvas';
    container.classList.remove('kernel-backdrop--css');

    // Clear any leftover CSS wash children from previous sessions (hot reload).
    for (const child of Array.from(container.children)) {
      if (!(child instanceof HTMLCanvasElement)) {
        // keep only engine canvases; badge is re-rendered by React after
      }
    }

    let engine: BackdropEngine | null = null;
    try {
      engine = new BackdropEngine(container, {
        theme: 'dark',
        initialKernel: requestedKernelRef.current,
        palette: resolveSkinPalette(skin),
        swarmEmberOptions: {
          enableSwarmSparkles: false,
          motionSpeedMultiplier: DASHBOARD_MOTION_SPEED_MULTIPLIER
        },
        onResolve: (id) => {
          setResolvedId(id);
          container.dataset.kernelResolved = id;
          // engineRef is set immediately after construct; constructor may call onResolve
          // before assignment, so read gl from the local binding.
          if (engine) {
            setGlOk(engine.glSupported);
            container.dataset.glSupported = engine.glSupported ? '1' : '0';
          }
        }
      });
    } catch (err) {
      console.error('[KernelBackdrop] BackdropEngine failed; CSS fallback', err);
      setMode('css');
      container.dataset.backdropMode = 'css';
      container.classList.add('kernel-backdrop--css');
      return;
    }

    engineRef.current = engine;
    setGlOk(engine.glSupported);
    setResolvedId(engine.getResolvedKernel());
    container.dataset.glSupported = engine.glSupported ? '1' : '0';
    container.dataset.kernelResolved = engine.getResolvedKernel();
    container.dataset.kernel = requestedKernelRef.current;

    // Ensure canvases fill the fixed viewport (engine sizes in px from container).
    const sizeCanvases = () => {
      const rect = container.getBoundingClientRect();
      if (rect.width < 2 || rect.height < 2) return;
      for (const canvas of container.querySelectorAll('canvas')) {
        canvas.style.width = `${rect.width}px`;
        canvas.style.height = `${rect.height}px`;
      }
    };
    sizeCanvases();
    const ro = new ResizeObserver(sizeCanvases);
    ro.observe(container);

    return () => {
      ro.disconnect();
      engine?.destroy();
      engineRef.current = null;
    };
  }, []);

  useEffect(() => {
    const container = containerRef.current;
    if (container) {
      container.dataset.kernel = kernelId;
      document.documentElement.dataset.kernel = kernelId;
    }
    engineRef.current?.setKernel(kernelId);
  }, [kernelId]);

  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;
    engine.setTheme('dark');
    engine.setPalette(resolveSkinPalette(skin));
  }, [skin]);

  return (
    <div
      ref={containerRef}
      className={`kernel-backdrop${mode === 'css' ? ' kernel-backdrop--css' : ''}`}
      data-kernel={kernelId}
      data-kernel-resolved={resolvedId}
      data-backdrop-mode={mode}
      data-gl={glOk === null ? 'unknown' : glOk ? '1' : '0'}
      aria-hidden="true"
    >
      <div className="kernel-backdrop-badge" aria-hidden="true">
        <span
          className="kernel-backdrop-badge-dot"
          data-gl={glOk ? '1' : '0'}
        />
        <span className="kernel-backdrop-badge-text">
          {resolvedId}
          {resolvedId !== kernelId ? ` ← ${kernelId}` : ''}
          {glOk === false ? ' · no-webgl2' : ''}
          {mode === 'css' ? ' · css-fallback' : ' · live'}
        </span>
      </div>
    </div>
  );
}
