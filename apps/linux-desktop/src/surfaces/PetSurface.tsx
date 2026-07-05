import { useEffect, useRef, useState } from 'react';
import { buildPetBehaviorGraph } from '../petBehaviorGraph.js';
import { detectPetTierFromEnv } from '../petCompanion.js';
import { mountPetGltfRuntime, stopPetGltfRuntime } from '../petGltfRuntime.js';

const PET_ASSET_URL = '/pets/kawaii-aurora-fox-actions.glb';

/**
 * Pet companion surface. The GLB runtime mounts imperatively into the stage
 * element; tier detection decides overlay pass-through vs the GNOME Wayland
 * draggable-contained fallback (never a silent click-through claim).
 */
export function PetSurface() {
  const stageRef = useRef<HTMLDivElement>(null);
  const [runtimeError, setRuntimeError] = useState<string | null>(null);
  const tier = detectPetTierFromEnv({
    XDG_SESSION_TYPE: 'wayland',
    XDG_CURRENT_DESKTOP: 'GNOME'
  });
  const graph = buildPetBehaviorGraph(tier.tier);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    let cancelled = false;
    void mountPetGltfRuntime(stage, PET_ASSET_URL).catch((error: unknown) => {
      if (cancelled) return;
      setRuntimeError(error instanceof Error ? error.message : 'Pet runtime failed to load.');
    });
    return () => {
      cancelled = true;
      stopPetGltfRuntime();
    };
  }, []);

  return (
    <>
      <div
        ref={stageRef}
        className="pet-stage"
        role="img"
        aria-label="Pet companion GLB preview"
        data-overlay-tier={tier.tier}
        data-input-passthrough={tier.tier === 'overlay-pass-through' ? 'true' : 'false'}
        {...(tier.tier === 'draggable-contained'
          ? {
              draggable: true,
              onDragStart: (event: React.DragEvent<HTMLDivElement>) =>
                event.dataTransfer?.setData('text/plain', 'openburnbar-pet-contained-fallback')
            }
          : {})}
      >
        Loading GLB pet runtime...
      </div>
      {runtimeError ? (
        <p className="muted" role="alert">
          {runtimeError}
        </p>
      ) : null}
      <p>{`Tier: ${tier.tier}`}</p>
      <p className="muted">{tier.message}</p>
      <p className="muted">
        {tier.tier === 'draggable-contained'
          ? 'Contained fallback is draggable and does not claim click-through/input passthrough.'
          : 'Overlay tier may pass input through only on compositor-supported sessions.'}
      </p>
      <p>{`glTF: ${graph.gltfAsset}`}</p>
      <pre className="pet-graph">{JSON.stringify(graph.nodes, null, 2)}</pre>
    </>
  );
}
