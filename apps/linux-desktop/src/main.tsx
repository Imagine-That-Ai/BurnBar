import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { applyReducedMotionClass, wireHiddenAnimationPause } from './a11y.js';
import { App } from './app/App.js';
import { readOnboarding } from './onboardingStore.js';
import { markStart } from './perfMarks.js';
import { useShellStore } from './state/shellStore.js';

async function boot(): Promise<void> {
  const end = markStart('app.start');
  applyReducedMotionClass();
  wireHiddenAnimationPause();

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
}

void boot();
