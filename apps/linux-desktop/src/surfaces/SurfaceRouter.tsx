import type { ComponentType } from 'react';
import { ROUTES, type ShellRoute } from '../routes.js';
import { SurfaceCard } from '../components/SurfaceCard.js';
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
  insights: makeDaemonSurface('insights', 'Insights'),
  database: makeDaemonSurface('database', 'Database'),
  providers: ProvidersSurface,
  projects: makeDaemonSurface('projects', 'Projects'),
  missions: makeDaemonSurface('missions', 'Missions'),
  activity: makeDaemonSurface('activity', 'Activity & logs'),
  chat: makeDaemonSurface('chat', 'Chat / Hermes'),
  memory: makeDaemonSurface('memory', 'Memory'),
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
    <SurfaceCard title={meta?.label ?? route} description={meta?.description ?? ''}>
      <Surface />
    </SurfaceCard>
  );
}
