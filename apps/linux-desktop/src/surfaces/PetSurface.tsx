import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent
} from 'react';
import { prefersReducedMotion } from '../a11y.js';
import { buildPetBehaviorGraph } from '../petBehaviorGraph.js';
import {
  petNativeContractFromStatus,
  probePetCapability,
  type PetCapabilityProbe
} from '../petCompanion.js';
import { mountPetGltfRuntime, stopPetGltfRuntime } from '../petGltfRuntime.js';
import {
  closePetCompanionWindow,
  openPetCompanionWindow,
  setPetCompanionClickThrough,
  type PetCompanionWindowState
} from '../petCompanionWindow.js';
import { openChatPopoutWindow } from './chat/chatWindow.js';
import { useShellStore } from '../state/shellStore.js';
import type { PetCompanionStatus } from '../tauriBridge.js';
import { BehaviorGraphView } from './pet/BehaviorGraphView.js';
import { TierMatrixTable } from './pet/TierMatrixTable.js';
import './pet/pet.css';

const PET_ASSET_URL = '/pets/kawaii-aurora-fox-actions.glb';

type ContainedPetOffset = {
  x: number;
  y: number;
};

type ContainedPetDrag = {
  pointerId: number;
  startX: number;
  startY: number;
  origin: ContainedPetOffset;
  last: ContainedPetOffset;
};

const CONTAINED_PET_OFFSET_LIMIT = { x: 96, y: 64 } as const;
const CONTAINED_PET_KEY_STEP = 16;

function clampContainedPetOffset(offset: ContainedPetOffset): ContainedPetOffset {
  return {
    x: Math.max(-CONTAINED_PET_OFFSET_LIMIT.x, Math.min(CONTAINED_PET_OFFSET_LIMIT.x, offset.x)),
    y: Math.max(-CONTAINED_PET_OFFSET_LIMIT.y, Math.min(CONTAINED_PET_OFFSET_LIMIT.y, offset.y))
  };
}

function containedPetOffsetLabel(offset: ContainedPetOffset): string {
  return `${offset.x},${offset.y}`;
}

/**
 * Pet companion surface. The GLB runtime mounts imperatively into the route
 * preview; the native runtime capability manifest decides whether an overlay
 * tier can be advertised. Environment variables are never treated as proof.
 */
export function PetSurface({ companionMode = false }: { companionMode?: boolean }) {
  const runtimeCapabilities = useShellStore((s) => s.runtimeCapabilities);
  const bridge = useShellStore((s) => s.bridge);
  const stageRef = useRef<HTMLDivElement>(null);
  const runtimeHostRef = useRef<HTMLDivElement>(null);
  const containedPetDragRef = useRef<ContainedPetDrag | null>(null);
  const [runtimeError, setRuntimeError] = useState<string | null>(null);
  const [runtimeState, setRuntimeState] = useState<'loading' | 'loaded' | 'error'>('loading');
  const [capability, setCapability] = useState<PetCapabilityProbe>(() => probePetCapability(null));
  const [nativeStatus, setNativeStatus] = useState<PetCompanionStatus | null>(null);
  const [companionWindow, setCompanionWindow] = useState<PetCompanionWindowState | null>(null);
  const [reactWaveActive, setReactWaveActive] = useState(false);
  const [containedPetSummoned, setContainedPetSummoned] = useState(false);
  const [containedPetSelected, setContainedPetSelected] = useState(false);
  const [containedActionStatus, setContainedActionStatus] = useState<string | null>(null);
  const [containedPetOffset, setContainedPetOffset] = useState<ContainedPetOffset>({ x: 0, y: 0 });
  const graph = buildPetBehaviorGraph(capability.tier);
  const containedFallback = !capability.actions.overlay.supported;

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
    const host = runtimeHostRef.current;
    if (!host) return;
    let cancelled = false;
    setRuntimeState('loading');
    setRuntimeError(null);
    void mountPetGltfRuntime(host, PET_ASSET_URL)
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

  const moveContainedPet = useCallback((offset: ContainedPetOffset, source: 'keyboard' | 'pointer') => {
    const next = clampContainedPetOffset(offset);
    setContainedPetOffset(next);
    setContainedActionStatus(
      `Contained preview moved ${source === 'keyboard' ? 'with the keyboard' : 'with pointer drag'} ` +
        `(${containedPetOffsetLabel(next)}). Press Home to reset.`
    );
  }, []);

  const handleContainedKeyDown = useCallback(
    (event: KeyboardEvent<HTMLDivElement>) => {
      if (!containedFallback) return;
      const step = event.shiftKey ? CONTAINED_PET_KEY_STEP * 3 : CONTAINED_PET_KEY_STEP;
      let delta: ContainedPetOffset | null = null;
      if (event.key === 'ArrowLeft') delta = { x: -step, y: 0 };
      if (event.key === 'ArrowRight') delta = { x: step, y: 0 };
      if (event.key === 'ArrowUp') delta = { x: 0, y: -step };
      if (event.key === 'ArrowDown') delta = { x: 0, y: step };
      if (event.key === 'Home') {
        event.preventDefault();
        moveContainedPet({ x: 0, y: 0 }, 'keyboard');
        return;
      }
      if (!delta) return;
      event.preventDefault();
      moveContainedPet(
        { x: containedPetOffset.x + delta.x, y: containedPetOffset.y + delta.y },
        'keyboard'
      );
    },
    [containedFallback, containedPetOffset, moveContainedPet]
  );

  const handleContainedPointerDown = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      if (!containedFallback || event.button !== 0) return;
      event.preventDefault();
      event.currentTarget.setPointerCapture?.(event.pointerId);
      containedPetDragRef.current = {
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        origin: containedPetOffset,
        last: containedPetOffset
      };
    },
    [containedFallback, containedPetOffset]
  );

  // WebViews without PointerEvent support (and assistive technology test
  // harnesses) still get the same bounded interaction through mouse events.
  // A pointer drag wins when both event families are emitted by the browser.
  const handleContainedMouseDown = useCallback(
    (event: ReactMouseEvent<HTMLDivElement>) => {
      if (!containedFallback || event.button !== 0 || containedPetDragRef.current) return;
      event.preventDefault();
      containedPetDragRef.current = {
        pointerId: -1,
        startX: event.clientX,
        startY: event.clientY,
        origin: containedPetOffset,
        last: containedPetOffset
      };
    },
    [containedFallback, containedPetOffset]
  );

  const handleContainedPointerMove = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      const drag = containedPetDragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      const next = clampContainedPetOffset({
        x: drag.origin.x + event.clientX - drag.startX,
        y: drag.origin.y + event.clientY - drag.startY
      });
      drag.last = next;
      setContainedPetOffset(next);
    },
    []
  );

  const handleContainedMouseMove = useCallback((event: ReactMouseEvent<HTMLDivElement>) => {
    const drag = containedPetDragRef.current;
    if (!drag || drag.pointerId !== -1) return;
    const next = clampContainedPetOffset({
      x: drag.origin.x + event.clientX - drag.startX,
      y: drag.origin.y + event.clientY - drag.startY
    });
    drag.last = next;
    setContainedPetOffset(next);
  }, []);

  const finishContainedPointerDrag = useCallback((event: PointerEvent<HTMLDivElement>) => {
    const drag = containedPetDragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    event.currentTarget.releasePointerCapture?.(event.pointerId);
    containedPetDragRef.current = null;
    if (drag.last.x !== drag.origin.x || drag.last.y !== drag.origin.y) {
      setContainedActionStatus(
        `Contained preview moved with pointer drag (${containedPetOffsetLabel(drag.last)}). Press Home to reset.`
      );
    }
  }, []);

  const finishContainedMouseDrag = useCallback((event: ReactMouseEvent<HTMLDivElement>) => {
    const drag = containedPetDragRef.current;
    if (!drag || drag.pointerId !== -1) return;
    containedPetDragRef.current = null;
    if (drag.last.x !== drag.origin.x || drag.last.y !== drag.origin.y) {
      setContainedActionStatus(
        `Contained preview moved with pointer drag (${containedPetOffsetLabel(drag.last)}). Press Home to reset.`
      );
    }
    event.preventDefault();
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

  const closeNativePet = useCallback(async () => {
    const closed = await closePetCompanionWindow();
    if (closed) {
      setCompanionWindow(null);
      setContainedActionStatus('Native companion window closed.');
    } else {
      setContainedActionStatus('Native companion window could not be closed.');
    }
  }, []);

  const openCompanionChat = useCallback(async () => {
    const opened = await openChatPopoutWindow();
    setContainedActionStatus(
      opened
        ? 'Chat opened in a separate window. The companion remains available here.'
        : 'A separate chat window is unavailable in this shell.'
    );
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
        aria-label={`Pet companion contained preview${containedPetSelected ? ', selected' : ''}`}
        aria-describedby={containedFallback ? 'pet-contained-move-help' : undefined}
        aria-keyshortcuts={containedFallback ? 'ArrowLeft ArrowRight ArrowUp ArrowDown Home' : undefined}
        tabIndex={containedFallback ? 0 : -1}
        onKeyDown={handleContainedKeyDown}
        onPointerDown={handleContainedPointerDown}
        onPointerMove={handleContainedPointerMove}
        onPointerUp={finishContainedPointerDrag}
        onPointerCancel={finishContainedPointerDrag}
        onMouseDown={handleContainedMouseDown}
        onMouseMove={handleContainedMouseMove}
        onMouseUp={finishContainedMouseDrag}
        data-overlay-tier={capability.tier}
        data-capability-state={capability.state}
        data-input-passthrough={companionWindow?.clickThrough ? 'true' : 'false'}
        data-pet-runtime={runtimeState}
        data-pet-summoned={containedPetSummoned ? 'true' : 'false'}
        data-pet-selected={containedPetSelected ? 'true' : 'false'}
        data-contained-fallback={containedFallback ? 'true' : 'false'}
        data-contained-offset={containedPetOffsetLabel(containedPetOffset)}
        style={
          {
            '--pet-contained-offset-x': `${containedPetOffset.x}px`,
            '--pet-contained-offset-y': `${containedPetOffset.y}px`
          } as React.CSSProperties
        }
        {...(containedFallback
          ? {
              draggable: true,
              onDragStart: (event: React.DragEvent<HTMLDivElement>) =>
                event.dataTransfer?.setData('text/plain', 'openburnbar-pet-contained-fallback')
            }
          : {})}
      >
        <div ref={runtimeHostRef} className="pet-stage-viewport">
          {runtimeState === 'loading' ? 'Loading GLB pet runtime...' : null}
        </div>
      </div>
      {containedFallback ? (
        <p id="pet-contained-move-help" className="sr-only">
          Drag the contained preview within this window, or focus it and use the arrow keys to reposition it. Press
          Home to reset its position.
        </p>
      ) : null}
      {companionMode ? (
        <div className="pet-actions pet-companion-actions" aria-label="Companion controls">
          <button type="button" className="pet-wave-button" onClick={waveAtPet}>
            Wave
          </button>
          <button type="button" className="pet-action-button" onClick={() => void openCompanionChat()}>
            Open chat
          </button>
        </div>
      ) : (
        <div className="pet-actions">
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
            <button
              type="button"
              className="pet-action-button"
              aria-keyshortcuts="Ctrl+Alt+Super+P"
              onClick={() => void summonNativePet()}
            >
              Open native companion
            </button>
          ) : null}
          {companionWindow?.opened ? (
            <>
              <button type="button" className="pet-action-button" onClick={() => void toggleNativeClickThrough()}>
                {companionWindow.clickThrough ? 'Restore companion interaction' : 'Enable click-through'}
              </button>
              <button type="button" className="pet-action-button" onClick={() => void closeNativePet()}>
                Close native companion
              </button>
            </>
          ) : null}
        </div>
      )}
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
