import { lazy, Suspense, useEffect, useState, type ComponentType } from 'react';
import { ROUTES, type ShellRoute } from '../routes.js';
import {
  capabilityBlocksSurface,
  findRuntimeCapability,
  type RuntimeCapabilityEntry
} from '../runtimeCapabilities.js';
import { useShellStore } from '../state/shellStore.js';
import { OnboardingSurface } from './OnboardingSurface.js';
import { OverviewSurface } from './OverviewSurface.js';
import { PetSurface } from './PetSurface.js';
import { SettingsSurface } from './SettingsSurface.js';
import { SupportSurface } from './SupportSurface.js';
import { UpdatesSurface } from './UpdatesSurface.js';
import { SurfaceErrorBoundary } from './SurfaceErrorBoundary.js';
import './capability-boundary.css';
import './system/system.css';

// Keep the first WebView payload focused on shell chrome and the current route.
// The previous eager registry pulled every dashboard, settings, media, and
// Computer Use surface into the initial chunk even when onboarding only needed
// one screen. Named-export adapters keep each split point explicit for Vite.
const InsightsSurface = lazy(() => import('./insights/InsightsSurface.js').then(({ InsightsSurface }) => ({ default: InsightsSurface })));
const DatabaseSurface = lazy(() => import('./database/DatabaseSurface.js').then(({ DatabaseSurface }) => ({ default: DatabaseSurface })));
const ProvidersSurface = lazy(() => import('./ProvidersSurface.js').then(({ ProvidersSurface }) => ({ default: ProvidersSurface })));
const ProjectsSurface = lazy(() => import('./projects/ProjectsSurface.js').then(({ ProjectsSurface }) => ({ default: ProjectsSurface })));
const MissionsSurface = lazy(() => import('./missions/MissionsSurface.js').then(({ MissionsSurface }) => ({ default: MissionsSurface })));
const ActivitySurface = lazy(() => import('./activity/ActivitySurface.js').then(({ ActivitySurface }) => ({ default: ActivitySurface })));
const ChatSurface = lazy(() => import('./chat/ChatSurface.js').then(({ ChatSurface }) => ({ default: ChatSurface })));
const MemorySurface = lazy(() => import('./memory/MemorySurface.js').then(({ MemorySurface }) => ({ default: MemorySurface })));
const ComputerUseSurface = lazy(() => import('./computerUse/ComputerUseSurface.js').then(({ ComputerUseSurface }) => ({ default: ComputerUseSurface })));
const MercurySurface = lazy(() => import('./media/MercurySurface.js').then(({ MercurySurface }) => ({ default: MercurySurface })));
const SmartHubSurface = lazy(() => import('./smarthub/SmartHubSurface.js').then(({ SmartHubSurface }) => ({ default: SmartHubSurface })));
const AccountSurface = lazy(() => import('./AccountSurface.js').then(({ AccountSurface }) => ({ default: AccountSurface })));
const TextExpansionSurface = lazy(() => import('./TextExpansionSurface.js').then(({ TextExpansionSurface }) => ({ default: TextExpansionSurface })));

type IdleDeadlineLike = {
  didTimeout: boolean;
  timeRemaining(): number;
};

type IdleSchedulerWindow = Window & {
  requestIdleCallback?: (callback: (deadline: IdleDeadlineLike) => void, options?: { timeout?: number }) => number;
  cancelIdleCallback?: (handle: number) => void;
};

/** Browser previews and fixture mode stay eager; only a real Tauri shell defers the heavy route body. */
export function isPackagedSurfaceMode(fixtureMode: boolean): boolean {
  return !fixtureMode && typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

function scheduleSurfaceBody(task: () => void): () => void {
  let cancelled = false;
  let firstFrame: number | null = null;
  let secondFrame: number | null = null;
  let timeout: number | null = null;
  let idleHandle: number | null = null;

  const run = () => {
    if (!cancelled) task();
  };

  const queueIdle = () => {
    if (cancelled) return;
    const idleWindow = window as IdleSchedulerWindow;
    if (idleWindow.requestIdleCallback) {
      idleHandle = idleWindow.requestIdleCallback(run, { timeout: 500 });
    } else {
      timeout = window.setTimeout(run, 0);
    }
  };

  if (typeof window.requestAnimationFrame === 'function') {
    firstFrame = window.requestAnimationFrame(() => {
      if (cancelled) return;
      secondFrame = window.requestAnimationFrame(queueIdle);
    });
  } else {
    timeout = window.setTimeout(queueIdle, 0);
  }

  return () => {
    cancelled = true;
    if (firstFrame !== null) window.cancelAnimationFrame(firstFrame);
    if (secondFrame !== null) window.cancelAnimationFrame(secondFrame);
    if (timeout !== null) window.clearTimeout(timeout);
    const idleWindow = window as IdleSchedulerWindow;
    if (idleHandle !== null) idleWindow.cancelIdleCallback?.(idleHandle);
  };
}

function SurfaceBodySkeleton({ label }: { label: string }) {
  return (
    <section
      className="system-skeleton surface-body-skeleton"
      role="status"
      aria-busy="true"
      aria-label={`Loading ${label}`}
    >
      <div className="system-skeleton-line" aria-hidden="true" />
      <div className="system-skeleton-line" aria-hidden="true" />
    </section>
  );
}

function SurfaceBody({
  Surface,
  route,
  label,
  defer
}: {
  Surface: ComponentType;
  route: ShellRoute;
  label: string;
  defer: boolean;
}) {
  const [ready, setReady] = useState(!defer);

  useEffect(() => {
    if (!defer) return;
    return scheduleSurfaceBody(() => setReady(true));
  }, [defer, route]);

  if (!defer || ready) return <Surface />;
  return <SurfaceBodySkeleton label={label} />;
}


const SURFACES: Record<ShellRoute, ComponentType> = {
  overview: OverviewSurface,
  insights: InsightsSurface,
  database: DatabaseSurface,
  providers: ProvidersSurface,
  projects: ProjectsSurface,
  missions: MissionsSurface,
  activity: ActivitySurface,
  chat: ChatSurface,
  memory: MemorySurface,
  'computer-use': ComputerUseSurface,
  mercury: MercurySurface,
  smarthub: SmartHubSurface,
  settings: SettingsSurface,
  account: AccountSurface,
  updates: UpdatesSurface,
  support: SupportSurface,
  onboarding: OnboardingSurface,
  pet: PetSurface,
  'text-expansion': TextExpansionSurface
};

export function SurfaceRouter({ route }: { route: ShellRoute }) {
  const meta = ROUTES.find((r) => r.id === route);
  const Surface = SURFACES[route];
  const bridge = useShellStore((state) => state.bridge);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const manifest = useShellStore((state) => state.runtimeCapabilities);
  const capabilityError = useShellStore((state) => state.capabilityError);
  const setRoute = useShellStore((state) => state.setRoute);

  let boundary: RuntimeCapabilityEntry | null = null;
  let contractFailure: string | null = null;
  if (!bridgeReady) {
    contractFailure = 'Checking this Linux session before enabling workflow controls.';
  } else if (bridge) {
    if (capabilityError || !manifest) {
      contractFailure = capabilityError ?? 'The runtime capability manifest is unavailable.';
    } else if (meta) {
      boundary = findRuntimeCapability(manifest, meta.requiredCapability);
      if (!boundary) {
        contractFailure = `The runtime manifest omitted ${meta.requiredCapability}.`;
      }
    }
  }

  const repairRoute: ShellRoute = route === 'support' ? 'onboarding' : 'support';
  const blocked = boundary ? capabilityBlocksSurface(boundary) : false;
  // Settings owns a bounded config loader and must mount immediately so its
  // bridge request cannot be starved behind the packaged route paint queue.
  // Other routes keep the deferred first paint budget.
  const deferSurfaceBody = isPackagedSurfaceMode(fixtureMode) && route !== 'settings';
  return (
    <div className="surface-bleed">
      <h2 id="route-title" className="sr-only">
        {meta?.label ?? route}
      </h2>
      {contractFailure ? (
        <section className="capability-boundary" role="status" aria-labelledby="capability-boundary-title">
          <span className="capability-boundary__icon capability-boundary__icon--spin" aria-hidden="true" />
          <div className="capability-boundary__body">
            <p className="capability-boundary__eyebrow">Runtime check</p>
            <h3 id="capability-boundary-title">{meta?.label ?? route} is not available yet</h3>
            <p>{contractFailure}</p>
          </div>
        </section>
      ) : blocked && boundary ? (
        <section className="capability-boundary" role="alert" aria-labelledby="capability-boundary-title">
          <span className="capability-boundary__icon" aria-hidden="true">!</span>
          <div className="capability-boundary__body">
            <p className="capability-boundary__eyebrow">{boundary.state}</p>
            <h3 id="capability-boundary-title">{meta?.label ?? route} is unavailable</h3>
            <p>{boundary.reason}</p>
            {boundary.substitute ? <p>{boundary.substitute}</p> : null}
            <button type="button" className="ghost capability-boundary__action" onClick={() => setRoute(repairRoute)}>
              {repairRoute === 'support' ? 'Open Support' : 'Open First-run setup'}
            </button>
          </div>
        </section>
      ) : (
        <>
          {boundary?.state === 'degraded' ? (
            <div className="capability-degraded" role="status">
              <span className="capability-degraded__icon" aria-hidden="true">!</span>
              <span>
                <strong>Limited in this session.</strong> {boundary.reason}
                {boundary.substitute ? ` ${boundary.substitute}` : ''}
              </span>
            </div>
          ) : null}
          <SurfaceErrorBoundary
            key={route}
            label={meta?.label ?? route}
            repairRoute={repairRoute}
            onRepair={() => setRoute(repairRoute)}
          >
            <Suspense fallback={<SurfaceBodySkeleton label={meta?.label ?? route} />}>
              <SurfaceBody
                Surface={Surface}
                route={route}
                label={meta?.label ?? route}
                defer={deferSurfaceBody}
              />
            </Suspense>
          </SurfaceErrorBoundary>
        </>
      )}
    </div>
  );
}
