import { useEffect, useRef } from 'react';
import { BackdropEngine } from '@openburnbar/gl-engine/engine/BackdropEngine';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { resolveSkinPalette } from '../lib/resolveSkinPalette.js';
import {
  DASHBOARD_MOTION_SPEED_MULTIPLIER
} from '../state/kernelPrefs.js';
import type { ShellSkin } from '../state/shellStore.js';

/**
 * Full-viewport kernel backdrop — Linux port of macOS `KernelBackdropView` +
 * dynamic `SwarmCanvasView` dashboard default (`swarmEmber`).
 *
 * Reads persisted kernel id (`openburnbar.linux.kernel.v1`), switches live via
 * `BackdropEngine.setKernel()`, and applies cinematic `motionSpeedMultiplier`
 * when the ember swarm kernel is active.
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
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    if (typeof process !== 'undefined' && process.env.VITEST) return;
    const probe = document.createElement('canvas');
    try {
      if (!probe.getContext('2d')) return;
    } catch {
      return;
    }

    const engine = new BackdropEngine(container, {
      theme: 'dark',
      initialKernel: kernelId,
      palette: resolveSkinPalette(skin),
      swarmEmberOptions: {
        enableSwarmSparkles: false,
        motionSpeedMultiplier: DASHBOARD_MOTION_SPEED_MULTIPLIER
      }
    });
    engineRef.current = engine;

    return () => {
      engine.destroy();
      engineRef.current = null;
    };
  }, []);

  useEffect(() => {
    engineRef.current?.setKernel(kernelId);
  }, [kernelId]);

  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;
    engine.setTheme('dark');
    engine.setPalette(resolveSkinPalette(skin));
  }, [skin]);

  return (
    <div ref={containerRef} className="kernel-backdrop" aria-hidden="true" />
  );
}