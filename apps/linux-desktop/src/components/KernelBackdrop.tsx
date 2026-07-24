import { useEffect, useRef, useState } from 'react';
import { BackdropEngine } from '@openburnbar/gl-engine/engine/BackdropEngine';
import type { KernelId, KernelResolution } from '@openburnbar/gl-engine/engine/types';
import { resolveSkinPalette } from '../lib/resolveSkinPalette.js';
import {
  DASHBOARD_MOTION_SPEED_MULTIPLIER
} from '../state/kernelPrefs.js';
import {
  readSwarmPreferences,
  SWARM_PREFS_CHANGED_EVENT,
  type SwarmPreferences
} from '../state/swarmPrefs.js';
import type { ShellSkin } from '../state/shellStore.js';

/** Window event used by the picker to mirror the backdrop's live capability receipt. */
export const KERNEL_RESOLUTION_EVENT = 'openburnbar:kernel-resolution';

function publishKernelResolution(container: HTMLElement, status: KernelResolution): void {
  container.dataset.kernelRequested = status.requestedId;
  container.dataset.kernelResolved = status.resolvedId;
  container.dataset.kernelResolution = status.reason;
  container.dataset.kernelFallback = status.fallback ? '1' : '0';
  container.dataset.kernelSubstrate = status.resolvedSubstrate;
  window.dispatchEvent(new CustomEvent<KernelResolution>(KERNEL_RESOLUTION_EVENT, { detail: status }));
}

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
  const [swarmPreferences, setSwarmPreferences] = useState<SwarmPreferences>(() => readSwarmPreferences());
  requestedKernelRef.current = kernelId;

  useEffect(() => {
    const onChange = (event: Event) => {
      const next = (event as CustomEvent<SwarmPreferences>).detail;
      setSwarmPreferences(next ?? readSwarmPreferences());
    };
    window.addEventListener(SWARM_PREFS_CHANGED_EVENT, onChange);
    return () => window.removeEventListener(SWARM_PREFS_CHANGED_EVENT, onChange);
  }, []);

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
          enableSwarmSparkles: swarmPreferences.constellationMode || swarmPreferences.sparkles,
          motionSpeedMultiplier: swarmPreferences.constellationMode
            ? 0.55
            : swarmPreferences.speed || DASHBOARD_MOTION_SPEED_MULTIPLIER,
          providerGlyphs: swarmPreferences.providerGlyphs,
          excludeBrandShapes: swarmPreferences.constellationMode || swarmPreferences.excludeBrandShapes,
          autoCycleShapes: swarmPreferences.constellationMode || swarmPreferences.autoCycleShapes,
          allowsClickCycle: swarmPreferences.constellationMode ? false : swarmPreferences.allowsClickCycle
        },
        onStatus: (status) => publishKernelResolution(container, status),
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
    container.dataset.kernelRequested = requestedKernelRef.current;
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
  }, [swarmPreferences]);

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
