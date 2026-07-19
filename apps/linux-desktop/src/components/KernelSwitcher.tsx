import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { KERNEL_META } from '@openburnbar/gl-engine/engine/registry';
import type { KernelId, KernelResolution } from '@openburnbar/gl-engine/engine/types';
import { readPersistedKernelId, writePersistedKernelId } from '../state/kernelPrefs.js';
import { KERNEL_RESOLUTION_EVENT } from './KernelBackdrop.js';
import './KernelSwitcher.css';

type Props = {
  kernelId: KernelId;
  onKernelChange: (id: KernelId) => void;
  className?: string;
};

/**
 * Lists all registry kernels (`KERNEL_META`, 32 entries) with persisted selection.
 * Mirrors macOS `KernelCatalog` + `KernelBackdropSettingsRow` picker binding.
 */
export function KernelSwitcher({ kernelId, onKernelChange, className }: Props) {
  const [open, setOpen] = useState(false);
  const [resolution, setResolution] = useState<KernelResolution | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const listId = useId();

  const activeLabel = useMemo(
    () => KERNEL_META.find((k) => k.id === kernelId)?.label ?? kernelId,
    [kernelId]
  );
  const fallbackForRequestedKernel =
    resolution?.requestedId === kernelId && resolution.fallback ? resolution : null;
  const fallbackLabel = fallbackForRequestedKernel
    ? fallbackForRequestedKernel.reason === 'webgl2-unavailable'
      ? '2D fallback (WebGL2 unavailable)'
      : `fallback (${fallbackForRequestedKernel.reason})`
    : null;

  useEffect(() => {
    const backdrop = document.querySelector<HTMLElement>('[data-kernel-requested]');
    if (
      backdrop?.dataset.kernelRequested === kernelId &&
      backdrop.dataset.kernelFallback === '1'
    ) {
      // The backdrop mounts before the chrome, so the initial event can happen
      // before this listener is attached. Rehydrate the deterministic receipt
      // from the host data attributes in that case.
      setResolution({
        requestedId: kernelId,
        resolvedId: (backdrop.dataset.kernelResolved as KernelId) || kernelId,
        requestedSubstrate: 'webgl2',
        resolvedSubstrate: '2d',
        reason: (backdrop.dataset.kernelResolution as KernelResolution['reason']) ||
          'context-unavailable',
        fallback: true,
        glSupported: backdrop.dataset.glSupported === '1'
      });
    } else {
      setResolution(null);
    }

    const onResolution = (event: Event) => {
      const status = (event as CustomEvent<KernelResolution>).detail;
      if (!status || status.requestedId !== kernelId) return;
      setResolution(status);
    };
    window.addEventListener(KERNEL_RESOLUTION_EVENT, onResolution);
    return () => window.removeEventListener(KERNEL_RESOLUTION_EVENT, onResolution);
  }, [kernelId]);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      const root = rootRef.current;
      if (root && !root.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  const select = (id: KernelId) => {
    writePersistedKernelId(id);
    onKernelChange(id);
    setOpen(false);
  };

  return (
    <div ref={rootRef} className={['kernel-switcher', className].filter(Boolean).join(' ')}>
      <button
        type="button"
        className="kernel-switcher-trigger"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={listId}
        title={fallbackLabel ? `${activeLabel}: ${fallbackLabel}` : activeLabel}
        onClick={() => setOpen((v) => !v)}
      >
        <span className="kernel-switcher-trigger-label">
          {fallbackLabel ? `${activeLabel} - ${fallbackLabel}` : activeLabel}
        </span>
        <span className="kernel-switcher-chevron" aria-hidden="true">
          ▾
        </span>
      </button>
      {open ? (
        <div id={listId} className="kernel-switcher-panel" role="listbox" aria-label="Backdrop kernel">
          <p className="kernel-switcher-section-label">Backdrop kernel</p>
          {KERNEL_META.map((kernel) => {
            const selected = kernel.id === kernelId;
            return (
              <button
                key={kernel.id}
                type="button"
                role="option"
                aria-selected={selected}
                aria-label={
                  selected && fallbackLabel
                    ? `${kernel.label}, ${fallbackLabel}`
                    : kernel.label
                }
                className={`kernel-switcher-item${selected ? ' kernel-switcher-item--selected' : ''}`}
                onClick={() => select(kernel.id)}
              >
                <span className="kernel-switcher-item-check" aria-hidden="true">
                  {selected ? '✓' : ''}
                </span>
                <span className="kernel-switcher-item-label">{kernel.label}</span>
                <span className="kernel-switcher-item-meta">{kernel.substrate}</span>
              </button>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}

/** Hook for backdrop host: persisted id + setter that writes localStorage. */
export function usePersistedKernelId(): [KernelId, (id: KernelId) => void] {
  const [kernelId, setKernelId] = useState<KernelId>(() => readPersistedKernelId());
  const setAndPersist = (id: KernelId) => {
    writePersistedKernelId(id);
    setKernelId(id);
  };
  return [kernelId, setAndPersist];
}
