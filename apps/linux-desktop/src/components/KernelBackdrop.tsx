import { useEffect, useRef, useState } from 'react';
import { BackdropEngine } from '@openburnbar/gl-engine/engine/BackdropEngine';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import type { BackdropReadabilityProfile } from '@openburnbar/gl-engine/engine/readability';
import { resolveSkinPalette } from '../lib/resolveSkinPalette.js';
import { fallbackProfileForSkin } from '../lib/adaptiveForeground.js';
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
  kernelId,
  onReadability
}: {
  skin: ShellSkin;
  kernelId: KernelId;
  onReadability: (profile: BackdropReadabilityProfile) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const engineRef = useRef<BackdropEngine | null>(null);
  const requestedKernelRef = useRef(kernelId);
  const onReadabilityRef = useRef(onReadability);
  const [mode, setMode] = useState<'canvas' | 'css'>('canvas');
  requestedKernelRef.current = kernelId;
  onReadabilityRef.current = onReadability;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    onReadabilityRef.current(fallbackProfileForSkin(skin));
    if (typeof process !== 'undefined' && process.env.VITEST) {
      setMode('css');
      container.dataset.backdropMode = 'css';
      return;
    }
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
        },
        onReadability: (profile) => onReadabilityRef.current(profile),
        readabilityRegions: () =>
          Array.from(document.querySelectorAll<HTMLElement>('[data-readability-region]'))
            .filter((element) => element.offsetParent !== null)
            .map((element) => element.getBoundingClientRect())
      });
    } catch (error) {
      console.error('[KernelBackdrop] engine initialization failed', error);
      setMode('css');
      container.dataset.backdropMode = 'css';
      onReadabilityRef.current(fallbackProfileForSkin(skin));
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
    if (mode === 'css') {
      onReadabilityRef.current(fallbackProfileForSkin(skin));
      return;
    }
    const engine = engineRef.current;
    if (!engine) return;
    engine.setTheme('dark');
    engine.setPalette(resolveSkinPalette(skin));
  }, [mode, skin]);

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
