import type { ComponentType } from 'react';
import { ROUTES, type ShellRoute } from '../routes.js';
import {
  capabilityBlocksSurface,
  findRuntimeCapability,
  type RuntimeCapabilityEntry
} from '../runtimeCapabilities.js';
import { useShellStore } from '../state/shellStore.js';
import { AccountSurface } from './AccountSurface.js';
import { OnboardingSurface } from './OnboardingSurface.js';
import { OverviewSurface } from './OverviewSurface.js';
import { PetSurface } from './PetSurface.js';
import { ProvidersSurface } from './ProvidersSurface.js';
import { SettingsSurface } from './SettingsSurface.js';
import { SupportSurface } from './SupportSurface.js';
import { TextExpansionSurface } from './TextExpansionSurface.js';
import { UpdatesSurface } from './UpdatesSurface.js';
import { ActivitySurface } from './activity/ActivitySurface.js';
import { DatabaseSurface } from './database/DatabaseSurface.js';
import { InsightsSurface } from './insights/InsightsSurface.js';
import { MemorySurface } from './memory/MemorySurface.js';
import { ChatSurface } from './chat/ChatSurface.js';
import { MissionsSurface } from './missions/MissionsSurface.js';
import { ProjectsSurface } from './projects/ProjectsSurface.js';
import { ComputerUseSurface } from './computerUse/ComputerUseSurface.js';
import { MercurySurface } from './media/MercurySurface.js';
import { SmartHubSurface } from './smarthub/SmartHubSurface.js';
import './capability-boundary.css';


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
          <Surface />
        </>
      )}
    </div>
  );
}
