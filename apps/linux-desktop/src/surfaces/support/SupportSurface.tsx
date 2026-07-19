import { useMemo, useSyncExternalStore, type ReactNode } from 'react';
import { KERNEL_META } from '@openburnbar/gl-engine/engine/registry';
import type { KernelResolution } from '@openburnbar/gl-engine/engine/types';
import { KERNEL_RESOLUTION_EVENT } from '../../components/KernelBackdrop.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { listPerfSamples } from '../../perfMarks.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSupportStore } from '../../state/supportStore.js';
import { Sparkline } from '../../components/Sparkline.js';
import { DAEMON_FIXTURE_AVAILABLE } from '../../daemonFixture.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { SystemStatusSection } from '../SystemStatusSection.js';
import { DiagnosticsExportCard } from './DiagnosticsExportCard.js';
import { DiagnosticsStatusSummary } from './DiagnosticsStatusSummary.js';
import { VersionGrid } from './VersionGrid.js';
import { MediaSection } from '../media/MediaSection.js';
import './support.css';

function usePerfSamples() {
  return useSyncExternalStore(
    (notify) => {
      const timer = setInterval(notify, 1000);
      return () => clearInterval(timer);
    },
    () => JSON.stringify(listPerfSamples())
  );
}

function groupPerfSamples(samples: { name: string; ms: number }[]) {
  const map = new Map<string, number[]>();
  for (const s of samples) {
    const list = map.get(s.name) ?? [];
    list.push(s.ms);
    map.set(s.name, list);
  }
  return [...map.entries()].map(([name, values]) => ({ name, values, latest: values[values.length - 1] }));
}

type BackdropRuntimeEvidence = {
  available: boolean;
  mode: string | null;
  requestedKernel: string | null;
  requestedSubstrate: string | null;
  resolvedKernel: string | null;
  resolvedSubstrate: string | null;
  resolution: string | null;
  fallback: boolean | null;
  glSupported: boolean | null;
};

const EMPTY_BACKDROP_RUNTIME_EVIDENCE: BackdropRuntimeEvidence = {
  available: false,
  mode: null,
  requestedKernel: null,
  requestedSubstrate: null,
  resolvedKernel: null,
  resolvedSubstrate: null,
  resolution: null,
  fallback: null,
  glSupported: null
};

let latestKernelResolution: KernelResolution | null = null;
let runtimeSubscriberCount = 0;

function readBackdropRuntimeEvidence(): string {
  if (typeof document === 'undefined') return JSON.stringify(EMPTY_BACKDROP_RUNTIME_EVIDENCE);

  const backdrop = document.querySelector<HTMLElement>('[data-backdrop-mode]');
  if (!backdrop && !latestKernelResolution) return JSON.stringify(EMPTY_BACKDROP_RUNTIME_EVIDENCE);

  const requestedKernel = backdrop?.dataset.kernelRequested?.trim() || latestKernelResolution?.requestedId || null;
  const resolvedKernel = backdrop?.dataset.kernelResolved?.trim() || latestKernelResolution?.resolvedId || null;
  const resolvedSubstrate =
    backdrop?.dataset.kernelSubstrate?.trim() || latestKernelResolution?.resolvedSubstrate || null;
  const glSupported =
    backdrop?.dataset.glSupported === '1'
      ? true
      : backdrop?.dataset.glSupported === '0'
        ? false
        : latestKernelResolution?.glSupported ?? null;
  const requestedSubstrate =
    KERNEL_META.find((kernel) => kernel.id === requestedKernel)?.substrate ??
    latestKernelResolution?.requestedSubstrate ??
    null;

  const evidence: BackdropRuntimeEvidence = {
    available: Boolean(requestedKernel && resolvedKernel && resolvedSubstrate && glSupported !== null),
    mode: backdrop?.dataset.backdropMode?.trim() || null,
    requestedKernel,
    requestedSubstrate,
    resolvedKernel,
    resolvedSubstrate,
    resolution: backdrop?.dataset.kernelResolution?.trim() || latestKernelResolution?.reason || null,
    fallback:
      backdrop?.dataset.kernelFallback === '1'
        ? true
        : backdrop?.dataset.kernelFallback === '0'
          ? false
          : latestKernelResolution?.fallback ?? null,
    glSupported
  };
  return JSON.stringify(evidence);
}

function subscribeBackdropRuntimeEvidence(onChange: () => void): () => void {
  if (typeof window === 'undefined') return () => undefined;

  runtimeSubscriberCount += 1;
  const onResolution = (event: Event) => {
    const detail = (event as CustomEvent<KernelResolution>).detail;
    if (
      detail &&
      typeof detail === 'object' &&
      typeof detail.requestedId === 'string' &&
      typeof detail.resolvedId === 'string' &&
      typeof detail.requestedSubstrate === 'string' &&
      typeof detail.resolvedSubstrate === 'string' &&
      typeof detail.reason === 'string' &&
      typeof detail.fallback === 'boolean' &&
      typeof detail.glSupported === 'boolean'
    ) {
      latestKernelResolution = detail;
    }
    onChange();
  };
  window.addEventListener(KERNEL_RESOLUTION_EVENT, onResolution);

  // The backdrop is mounted before the Support route and publishes its first
  // receipt from an effect. Attribute observation covers that initial mount,
  // later context-loss recovery, and kernel switches without polling.
  const observer = typeof MutationObserver === 'undefined' ? null : new MutationObserver(onChange);
  const target = document.documentElement;
  observer?.observe(target, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: [
      'data-backdrop-mode',
      'data-gl-supported',
      'data-kernel-fallback',
      'data-kernel-requested',
      'data-kernel-resolution',
      'data-kernel-resolved',
      'data-kernel-substrate'
    ]
  });

  return () => {
    window.removeEventListener(KERNEL_RESOLUTION_EVENT, onResolution);
    observer?.disconnect();
    runtimeSubscriberCount = Math.max(0, runtimeSubscriberCount - 1);
    if (runtimeSubscriberCount === 0) latestKernelResolution = null;
  };
}

function useBackdropRuntimeEvidence(): BackdropRuntimeEvidence {
  const snapshot = useSyncExternalStore(
    subscribeBackdropRuntimeEvidence,
    readBackdropRuntimeEvidence,
    readBackdropRuntimeEvidence
  );
  return JSON.parse(snapshot) as BackdropRuntimeEvidence;
}

function kernelLabel(id: string | null): string {
  if (!id) return 'Unavailable';
  return KERNEL_META.find((kernel) => kernel.id === id)?.label ?? id;
}

function runtimeValue(value: string | null): string {
  return value ?? 'Unavailable';
}

function BackdropRuntimeRow() {
  const evidence = useBackdropRuntimeEvidence();
  const bridge = useShellStore((state) => state.bridge);
  const fixtureMode = useShellStore((state) => state.fixtureMode);

  const source = evidence.available
    ? 'Live renderer receipt'
    : fixtureMode
      ? 'Fixture data (no live renderer receipt)'
      : bridge
        ? 'Packaged shell (renderer receipt unavailable)'
        : 'Browser preview (packaged shell unavailable)';
  const description = evidence.available
    ? 'The backdrop reported the kernel and graphics capability it is actually using.'
    : fixtureMode
      ? 'Fixture mode does not fabricate WebGL2 or kernel facts. Run the packaged shell for a live renderer receipt.'
      : bridge
        ? 'The packaged shell is present, but the backdrop has not reported a live renderer receipt yet.'
        : 'This browser preview cannot verify the packaged renderer. Install and launch the Linux app for live facts.';
  const rendererState = evidence.fallback
    ? evidence.resolution === 'webgl2-unavailable'
      ? '2D fallback (WebGL2 unavailable)'
      : `Fallback (${runtimeValue(evidence.resolution)})`
    : evidence.available
      ? 'Native'
      : 'Unavailable';
  const webgl2 = evidence.glSupported === true
    ? 'Available'
    : evidence.glSupported === false
      ? 'Unavailable'
      : 'Unavailable';

  const rows = [
    { label: 'Requested kernel', value: kernelLabel(evidence.requestedKernel) },
    { label: 'Resolved kernel', value: kernelLabel(evidence.resolvedKernel) },
    { label: 'Requested substrate', value: runtimeValue(evidence.requestedSubstrate) },
    { label: 'Active substrate', value: runtimeValue(evidence.resolvedSubstrate) },
    { label: 'WebGL2 capability', value: webgl2 },
    { label: 'Renderer state', value: rendererState }
  ];

  return (
    <section
      className="p09-runtime-card"
      aria-labelledby="p09-runtime-heading"
      aria-live="polite"
      data-provenance={evidence.available ? 'renderer' : fixtureMode ? 'fixture-unavailable' : 'unavailable'}
    >
      <div className="p09-runtime-card__header">
        <div>
          <h3 id="p09-runtime-heading">Backdrop runtime</h3>
          <p className="muted">{description}</p>
        </div>
        <span className={`p09-runtime-card__state${evidence.available ? ' p09-runtime-card__state--ok' : ''}`}>
          {evidence.available ? source : 'Unavailable'}
        </span>
      </div>
      <dl className="p09-runtime-facts" aria-label="Backdrop renderer facts">
        {rows.map((row) => (
          <div className="p09-runtime-fact" key={row.label}>
            <dt>{row.label}</dt>
            <dd>{row.value}</dd>
          </div>
        ))}
      </dl>
      {!evidence.available ? <p className="p09-runtime-unavailable" role="status">Live backdrop capability data is unavailable.</p> : null}
    </section>
  );
}

export function SupportSurface() {
  const samplesJson = usePerfSamples();
  const samples = JSON.parse(samplesJson) as { name: string; ms: number }[];
  const grouped = useMemo(() => groupPerfSamples(samples), [samples]);
  const trayDegraded = useShellStore((s) => s.trayDegraded);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const setFixtureMode = useShellStore((s) => s.setFixtureMode);
  const status = useDaemonStatusCopy();
  const versionInfo = useSupportStore((s) => s.versionInfo);
  const versionLoading = useSupportStore((s) => s.versionLoading);
  const versionError = useSupportStore((s) => s.versionError);
  const loadVersion = useSupportStore((s) => s.loadVersion);

  useLaneLoad(loadVersion);

  let versionBlock: ReactNode;
  if (versionLoading && !versionInfo) {
    versionBlock = <p className="muted">Loading version facts…</p>;
  } else if (versionError && !versionInfo) {
    versionBlock = (
      <OfflineNotice
        status={status}
        summary="Support can still export diagnostics when the packaged shell is available."
        fixtureMode={fixtureMode}
      />
    );
  } else if (versionInfo) {
    versionBlock = <VersionGrid info={versionInfo} />;
  } else {
    versionBlock = (
      <OfflineNotice
        status={status}
        summary="Enable fixture mode or use the packaged shell for version facts."
        fixtureMode={fixtureMode}
      />
    );
  }

  return (
    <>
      <SystemStatusSection />
      <DiagnosticsStatusSummary />
      <BackdropRuntimeRow />
      {versionBlock}
      <DiagnosticsExportCard />
      <MediaSection />
      <table className="table p09-perf-table">
        <thead>
          <tr>
            <th>Perf sample</th>
            <th>ms</th>
            <th>Trend</th>
          </tr>
        </thead>
        <tbody>
          {grouped.length === 0 ? (
            <tr>
              <td className="p09-perf-empty" colSpan={3} role="status">
                No performance samples yet. Use the app normally and this table will populate automatically.
              </td>
            </tr>
          ) : (
            grouped.map((row) => (
              <tr key={row.name}>
                <td>{row.name}</td>
                <td>{row.latest.toFixed(1)}</td>
                <td>
                  <Sparkline values={row.values} label={`${row.name} perf trend`} />
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
      {trayDegraded ? <p className="muted">Tray degraded: use window reopen from launcher.</p> : null}
      {DAEMON_FIXTURE_AVAILABLE ? (
        <div className="p09-fixture-controls" role="group" aria-label="Diagnostic data source">
          <p className="muted">
            Fixture data is synthetic and intended only for host smoke tests. It never represents a packaged
            daemon or writes a native export bundle.
          </p>
          <button
            type="button"
            className="ghost"
            aria-pressed={fixtureMode}
            onClick={() => setFixtureMode(!fixtureMode)}
          >
            {fixtureMode ? 'Disable fixture data' : 'Enable fixture data (host smoke only)'}
          </button>
        </div>
      ) : null}
    </>
  );
}
