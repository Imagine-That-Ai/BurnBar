import type { ComponentType } from 'react';
import { ROUTES, type ShellRoute } from '../routes.js';
import { AccountSurface } from './AccountSurface.js';
import { DaemonDataSection } from './DaemonDataSection.js';
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
import { CommunitySurface } from '../community/CommunitySurface.js';
import { MemorySurface } from './memory/MemorySurface.js';
import { ChatSurface } from './chat/ChatSurface.js';
import { MissionsSurface } from './missions/MissionsSurface.js';
import { ProjectsSurface } from './projects/ProjectsSurface.js';

/**
 * Route → surface registry. Task-packet lanes extend this map by REPLACING a
 * generic daemon-data surface with a purpose-built one — never by editing
 * another lane's surface. Routes without a dedicated surface render the
 * shared DaemonDataSection with honest degraded states.
 */
function makeDaemonSurface(route: ShellRoute, label: string): ComponentType {
  return function DaemonSurface() {
    return <DaemonDataSection route={route} label={label} />;
  };
}

const SURFACES: Record<ShellRoute, ComponentType> = {
  overview: OverviewSurface,
  community: CommunitySurface,
  database: DatabaseSurface,
  providers: ProvidersSurface,
  projects: ProjectsSurface,
  missions: MissionsSurface,
  activity: ActivitySurface,
  chat: ChatSurface,
  memory: MemorySurface,
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
  return (
    <div className="surface-bleed">
      <h2 id="route-title" className="sr-only">
        {meta?.label ?? route}
      </h2>
      <Surface />
    </div>
  );
}