import { useCallback, useEffect, useRef, useState } from 'react';
import { prefersReducedMotion } from '../a11y.js';
import { buildPetBehaviorGraph } from '../petBehaviorGraph.js';
import { detectPetTierFromEnv, type PetTier } from '../petCompanion.js';
import { mountPetGltfRuntime, stopPetGltfRuntime } from '../petGltfRuntime.js';
import { useShellStore } from '../state/shellStore.js';
import type { SessionEnv } from '../tauriBridge.js';
import { BehaviorGraphView } from './pet/BehaviorGraphView.js';
import { TierMatrixTable } from './pet/TierMatrixTable.js';
import './pet/pet.css';

const PET_ASSET_URL = '/pets/kawaii-aurora-fox-actions.glb';

const PREVIEW_ENV: SessionEnv = {
  XDG_SESSION_TYPE: 'wayland',
  XDG_CURRENT_DESKTOP: 'GNOME'
};

type PetTierEnvResult = {
  tier: PetTier;
  compositor: string;
  message: string;
};

export type PetTierDetection = PetTierEnvResult & { previewAssumption: boolean };


/**
 * Pet companion surface. The GLB runtime mounts imperatively into the stage
 * element; tier detection decides overlay pass-through vs the GNOME Wayland
 * draggable-contained fallback (never a silent click-through claim).
 */
export function PetSurface() {
  const bridge = useShellStore((s) => s.bridge);
  const stageRef = useRef<HTMLDivElement>(null);
  const [runtimeError, setRuntimeError] = useState<string | null>(null);
  const [runtimeState, setRuntimeState] = useState<'loading' | 'loaded' | 'error'>('loading');
  const [tierInfo, setTierInfo] = useState<PetTierDetection>(() => {
    const detected = detectPetTierFromEnv(PREVIEW_ENV);
    return { ...detected, previewAssumption: true };
  });
  const [reactWaveActive, setReactWaveActive] = useState(false);
  const graph = buildPetBehaviorGraph(tierInfo.tier);

  useEffect(() => {
    let cancelled = false;
    async function resolveTier(): Promise<void> {
      if (!bridge) {
        const detected = detectPetTierFromEnv(PREVIEW_ENV);
        if (!cancelled) {
          setTierInfo({ ...detected, previewAssumption: true });
        }
        return;
      }
      try {
        const env = await bridge.sessionEnv();
        const detected = detectPetTierFromEnv(env);
        if (!cancelled) {
          setTierInfo({ ...detected, previewAssumption: false });
        }
      } catch {
        const detected = detectPetTierFromEnv(PREVIEW_ENV);
        if (!cancelled) {
          setTierInfo({ ...detected, previewAssumption: true });
        }
      }
    }
    void resolveTier();
    return () => {
      cancelled = true;
    };
  }, [bridge]);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    let cancelled = false;
    setRuntimeState('loading');
    setRuntimeError(null);
    void mountPetGltfRuntime(stage, PET_ASSET_URL)
      .then(() => {
        if (cancelled) return;
        setRuntimeState('loaded');
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        setRuntimeState('error');
        setRuntimeError(error instanceof Error ? error.message : 'Pet runtime failed to load.');
      });
    return () => {
      cancelled = true;
      stopPetGltfRuntime();
    };
  }, []);

  const waveAtPet = useCallback(() => {
    setReactWaveActive(true);
    window.setTimeout(() => setReactWaveActive(false), prefersReducedMotion() ? 1200 : 2000);
  }, []);

  const stageClasses = [
    'pet-stage',
    reactWaveActive ? 'pet-stage--react-wave' : '',
    reactWaveActive && !prefersReducedMotion() ? 'pet-stage--react-wave-pulse' : ''
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div className="pet-surface">
      <div
        ref={stageRef}
        className={stageClasses}
        role="img"
        aria-label="Pet companion GLB preview"
        data-overlay-tier={tierInfo.tier}
        data-input-passthrough={tierInfo.tier === 'overlay-pass-through' ? 'true' : 'false'}
        data-pet-runtime={runtimeState}
        {...(tierInfo.tier === 'draggable-contained'
          ? {
              draggable: true,
              onDragStart: (event: React.DragEvent<HTMLDivElement>) =>
                event.dataTransfer?.setData('text/plain', 'openburnbar-pet-contained-fallback')
            }
          : {})}
      >
        {runtimeState === 'loading' ? 'Loading GLB pet runtime...' : null}
      </div>
      <div className="pet-actions">
        <button type="button" className="pet-wave-button" onClick={waveAtPet}>
          Wave at pet
        </button>
      </div>
      {runtimeError ? (
        <p className="muted" role="alert">
          {runtimeError}
        </p>
      ) : null}
      {tierInfo.previewAssumption ? (
        <p className="pet-preview-note">Tier detection uses preview assumption (no packaged session env).</p>
      ) : null}
      <p>{`Tier: ${tierInfo.tier}`}</p>
      <p className="muted">{tierInfo.message}</p>
      <p className="muted">
        {tierInfo.tier === 'draggable-contained'
          ? 'Contained fallback is draggable and does not claim click-through/input passthrough.'
          : 'Overlay tier may pass input through only on compositor-supported sessions.'}
      </p>
      <p>{`glTF: ${graph.gltfAsset}`}</p>
      <BehaviorGraphView graph={graph} />
      <TierMatrixTable />
    </div>
  );
}