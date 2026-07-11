import { useEffect, useRef, useState } from 'react';
import { BackdropEngine } from '@openburnbar/gl-engine/engine/BackdropEngine';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { resolveSkinPalette } from '../lib/resolveSkinPalette.js';
import {
  DASHBOARD_MOTION_SPEED_MULTIPLIER
} from '../state/kernelPrefs.js';
import type { ShellSkin } from '../state/shellStore.js';

/**
 * Real gl-engine backdrop with a Canvas2D fallback for WebKitGTK hosts that
 * cannot expose WebGL2. The emergency CSS fallback is only used when canvas
 * construction itself fails or is explicitly requested in localStorage.
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
  const [mode, setMode] = useState<'canvas' | 'css'>('canvas');
  requestedKernelRef.current = kernelId;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    if (typeof process !== 'undefined' && process.env.VITEST) return;
    const forcedMode =
      typeof localStorage === 'undefined'
        ? null
        : localStorage.getItem('openburnbar.linux.backdrop.mode.v1');
    if (forcedMode === 'css') {
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

    let engine: BackdropEngine;
    try {
      engine = new BackdropEngine(container, {
        theme: 'dark',
        initialKernel: requestedKernelRef.current,
        palette: resolveSkinPalette(skin),
        swarmEmberOptions: {
          enableSwarmSparkles: false,
          motionSpeedMultiplier: DASHBOARD_MOTION_SPEED_MULTIPLIER
        },
        onResolve: (resolvedId) => {
          container.dataset.kernelResolved = resolvedId;
        }
      });
    } catch (error) {
      console.error('[KernelBackdrop] engine initialization failed', error);
      setMode('css');
      container.dataset.backdropMode = 'css';
      return;
    }

    engineRef.current = engine;
    container.dataset.backdropMode = 'canvas';
    container.dataset.kernel = requestedKernelRef.current;
    container.dataset.glSupported = engine.glSupported ? '1' : '0';

    const resize = () => {
      const rect = container.getBoundingClientRect();
      if (rect.width < 2 || rect.height < 2) return;
      for (const canvas of container.querySelectorAll('canvas')) {
        canvas.style.width = `${rect.width}px`;
        canvas.style.height = `${rect.height}px`;
      }
    };
    resize();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(resize);
    observer?.observe(container);

    return () => {
      observer?.disconnect();
      engine.destroy();
      engineRef.current = null;
    };
  }, []);

  useEffect(() => {
    if (containerRef.current) {
      containerRef.current.dataset.kernel = kernelId;
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
      data-backdrop-mode={mode}
      aria-hidden="true"
    />
  );
}
