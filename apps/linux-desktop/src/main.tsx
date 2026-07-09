import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { applyReducedMotionClass } from './a11y.js';
import { App } from './app/App.js';
import { readOnboarding } from './onboardingStore.js';
import { markStart } from './perfMarks.js';
import { DaemonHealthSupervisor, installDaemonHealthLifecycle } from './state/daemonHealthSupervisor.js';
import { useShellStore } from './state/shellStore.js';

async function boot(): Promise<void> {
  const end = markStart('app.start');
  applyReducedMotionClass();

  // First run lands on the onboarding wizard unless a deep link is present.
  const ob = readOnboarding();
  if (!ob.completed && !location.hash) {
    location.hash = '#/onboarding';
    useShellStore.getState().syncRouteFromHash();
  }

  const root = document.getElementById('root');
  if (!root) throw new Error('Missing #root mount point');
  createRoot(root).render(
    <StrictMode>
      <App />
    </StrictMode>
  );

  await useShellStore.getState().boot();
  end();

  const healthSupervisor = new DaemonHealthSupervisor(async () => {
    await useShellStore.getState().refreshHealth();
    return useShellStore.getState().health?.ok === true;
  });
  const uninstallHealthLifecycle = installDaemonHealthLifecycle(healthSupervisor);
  window.addEventListener('beforeunload', uninstallHealthLifecycle, { once: true });
}

void boot();
