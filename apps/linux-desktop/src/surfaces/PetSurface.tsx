import { useCallback, useEffect, useRef, useState } from 'react';
import { prefersReducedMotion } from '../a11y.js';
import { buildPetBehaviorGraph } from '../petBehaviorGraph.js';
import {
  petNativeContractFromStatus,
  probePetCapability,
  type PetCapabilityProbe
} from '../petCompanion.js';
import { mountPetGltfRuntime, stopPetGltfRuntime } from '../petGltfRuntime.js';
import {
  openPetCompanionWindow,
  setPetCompanionClickThrough,
  type PetCompanionWindowState
} from '../petCompanionWindow.js';
import { useShellStore } from '../state/shellStore.js';
import type { PetCompanionStatus } from '../tauriBridge.js';
import { BehaviorGraphView } from './pet/BehaviorGraphView.js';
import { TierMatrixTable } from './pet/TierMatrixTable.js';
import './pet/pet.css';

const PET_ASSET_URL = '/pets/kawaii-aurora-fox-actions.glb';

/**
 * Pet companion surface. The GLB runtime mounts imperatively into the route
 * preview; the native runtime capability manifest decides whether an overlay
 * tier can be advertised. Environment variables are never treated as proof.
 */
export function PetSurface({ companionMode = false }: { companionMode?: boolean }) {
  const runtimeCapabilities = useShellStore((s) => s.runtimeCapabilities);
  const bridge = useShellStore((s) => s.bridge);
  const stageRef = useRef<HTMLDivElement>(null);
  const [runtimeError, setRuntimeError] = useState<string | null>(null);
  const [runtimeState, setRuntimeState] = useState<'loading' | 'loaded' | 'error'>('loading');
  const [capability, setCapability] = useState<PetCapabilityProbe>(() => probePetCapability(null));
  const [nativeStatus, setNativeStatus] = useState<PetCompanionStatus | null>(null);
  const [companionWindow, setCompanionWindow] = useState<PetCompanionWindowState | null>(null);
  const [reactWaveActive, setReactWaveActive] = useState(false);
  const [containedPetSummoned, setContainedPetSummoned] = useState(false);
  const [containedPetSelected, setContainedPetSelected] = useState(false);
  const [containedActionStatus, setContainedActionStatus] = useState<string | null>(null);
  const graph = buildPetBehaviorGraph(capability.tier);

  useEffect(() => {
    setCapability(probePetCapability(runtimeCapabilities, petNativeContractFromStatus(nativeStatus)));
  }, [nativeStatus, runtimeCapabilities]);

  useEffect(() => {
    if (!bridge?.petCompanionStatus) {
      setNativeStatus(null);
      return;
    }
    let cancelled = false;
    void bridge.petCompanionStatus()
      .then((status) => {
        if (!cancelled) setNativeStatus(status);
      })
      .catch(() => {
        if (!cancelled) setNativeStatus(null);
      });
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

  const summonContainedPet = useCallback(() => {
    const stage = stageRef.current;
    if (!stage || !capability.containedActions.summon.supported) return;
    setContainedPetSummoned(true);
    stage.scrollIntoView?.({
      block: 'center',
      behavior: prefersReducedMotion() ? 'auto' : 'smooth'
    });
    stage.focus({ preventScroll: true });
    setContainedActionStatus('Contained preview summoned in this window. Native overlay behavior remains unavailable.');
  }, [capability.containedActions.summon.supported]);

  const selectContainedPet = useCallback(() => {
    if (!capability.containedActions.selection.supported) return;
    setContainedPetSelected((selected) => {
      const next = !selected;
      setContainedActionStatus(
        next
          ? 'Contained pet selected in this window. Native desktop selection remains unavailable.'
          : 'Contained pet selection cleared.'
      );
      return next;
    });
    stageRef.current?.focus({ preventScroll: true });
  }, [capability.containedActions.selection.supported]);

  const summonNativePet = useCallback(async () => {
    if (!capability.actions.overlay.supported) return;
    const result = await openPetCompanionWindow();
    setCompanionWindow(result);
    setNativeStatus(result.status);
    setContainedActionStatus(
      result.opened
        ? 'Native X11 companion window opened and focused. Input pass-through is opt-in.'
        : result.status.reason
    );
  }, [capability.actions.overlay.supported]);

  const toggleNativeClickThrough = useCallback(async () => {
    const result = await setPetCompanionClickThrough(!companionWindow?.clickThrough);
    setCompanionWindow(result);
    setNativeStatus(result.status);
    setContainedActionStatus(
      result.opened
        ? result.clickThrough
          ? 'Input pass-through enabled. Use the main OpenBurnBar window to restore interaction.'
          : 'Input pass-through disabled and the companion window is focused.'
        : result.status.reason
    );
  }, [companionWindow?.clickThrough]);

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
        aria-label={`Pet companion contained preview${containedPetSelected ? ', selected' : ''}`}
        tabIndex={-1}
        data-overlay-tier={capability.tier}
        data-capability-state={capability.state}
        data-input-passthrough={companionWindow?.clickThrough ? 'true' : 'false'}
        data-pet-runtime={runtimeState}
        data-pet-summoned={containedPetSummoned ? 'true' : 'false'}
        data-pet-selected={containedPetSelected ? 'true' : 'false'}
        {...(!capability.actions.overlay.supported
          ? {
              draggable: true,
              onDragStart: (event: React.DragEvent<HTMLDivElement>) =>
                event.dataTransfer?.setData('text/plain', 'openburnbar-pet-contained-fallback')
            }
          : {})}
      >
        {runtimeState === 'loading' ? 'Loading GLB pet runtime...' : null}
      </div>
      {!companionMode ? <div className="pet-actions">
        <button type="button" className="pet-wave-button" onClick={waveAtPet}>
          Wave at preview
        </button>
        <button
          type="button"
          className="pet-action-button"
          onClick={summonContainedPet}
          disabled={!capability.containedActions.summon.supported}
        >
          Summon contained preview
        </button>
        <button
          type="button"
          className="pet-action-button"
          onClick={selectContainedPet}
          disabled={!capability.containedActions.selection.supported}
          aria-pressed={containedPetSelected}
        >
          {containedPetSelected ? 'Pet selected' : 'Select contained pet'}
        </button>
        {capability.actions.overlay.supported ? (
          <button type="button" className="pet-action-button" onClick={() => void summonNativePet()}>
            Open native companion
          </button>
        ) : null}
        {companionWindow?.opened ? (
          <button type="button" className="pet-action-button" onClick={() => void toggleNativeClickThrough()}>
            {companionWindow.clickThrough ? 'Restore companion interaction' : 'Enable click-through'}
          </button>
        ) : null}
      </div> : null}
      {containedActionStatus ? (
        <p className="pet-action-status" role="status" aria-live="polite">
          {containedActionStatus}
        </p>
      ) : null}
      {runtimeError ? (
        <p className="muted" role="alert">
          {runtimeError}
        </p>
      ) : null}
      {capability.previewOnly && !companionMode ? (
        <p className="pet-preview-note" role="status">
          Preview only: the packaged runtime capability probe is unavailable, so overlay and input pass-through remain
          disabled.
        </p>
      ) : null}
      {!companionMode ? <>
        <p>{`Tier: ${capability.tier}`}</p>
        <p>{`Capability: ${capability.state}`}</p>
        {capability.compositor ? <p className="muted">{`Session: ${capability.compositor}`}</p> : null}
        <p className="muted">{capability.message}</p>
        {capability.substitute ? <p className="muted">{capability.substitute}</p> : null}
        <p className="muted">
          {capability.actions['click-through'].supported
            ? companionWindow?.clickThrough
              ? 'Input pass-through is enabled for the native companion window.'
              : 'Native input pass-through is available but remains disabled until explicitly enabled.'
            : 'Contained fallback is draggable and does not claim click-through or desktop-level interaction.'}
        </p>
      </> : null}
      {!companionMode ? <section className="pet-capability-section" aria-labelledby="pet-capabilities-title">
        <h3 id="pet-capabilities-title" className="pet-section-title">
          Native companion capabilities
        </h3>
        <dl className="pet-capability-list">
          {(
            Object.entries(capability.actions) as Array<
              [keyof PetCapabilityProbe['actions'], PetCapabilityProbe['actions'][keyof PetCapabilityProbe['actions']]]
            >
          ).map(([action, status]) => (
            <div className="pet-capability-row" key={action}>
              <dt>{action === 'click-through' ? 'Input pass-through' : action[0].toUpperCase() + action.slice(1)}</dt>
              <dd>
                <strong>{status.supported ? 'Available' : 'Unavailable'}</strong>
                <span>{status.reason}</span>
              </dd>
            </div>
          ))}
        </dl>
      </section> : null}
      {!companionMode ? <>
        <p>{`glTF: ${graph.gltfAsset}`}</p>
        <BehaviorGraphView graph={graph} />
        <TierMatrixTable />
      </> : null}
    </div>
  );
}
