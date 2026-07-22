import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { applyReducedMotionClass } from './a11y.js';
import { App } from './app/App.js';
import {
  cacheOnboarding,
  readOnboarding,
  shouldRouteToOnboarding
} from './onboardingStore.js';
import { markStart } from './perfMarks.js';
import { DaemonHealthSupervisor, installDaemonHealthLifecycle } from './state/daemonHealthSupervisor.js';
import {
  DaemonSubscriptionSupervisor,
  installDaemonSubscriptionLifecycle
} from './state/daemonSubscriptionSupervisor.js';
import { useShellStore } from './state/shellStore.js';

async function boot(): Promise<void> {
  const end = markStart('app.start');
  applyReducedMotionClass();
  let requestedHash = location.hash;
  let hadDeepLink = Boolean(requestedHash && requestedHash !== '#/onboarding');

  // First run lands on the onboarding wizard unless a deep link is present.
  const ob = readOnboarding();
  if (location.hash !== '#/onboarding') {
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
  const bridge = useShellStore.getState().bridge;
  if (bridge) {
    try {
      const startupDeepLink = await bridge.startupDeepLink?.();
      if (startupDeepLink) {
        requestedHash = `#/${startupDeepLink.route}`;
        hadDeepLink = true;
        // The native command returns a typed, allowlisted handoff. Keep the
        // browser URL opaque and let the destination surface decide when it
        // can consume OAuth or membership state safely.
        window.dispatchEvent(new CustomEvent('openburnbar-deep-link', { detail: startupDeepLink }));
      }
    } catch (error) {
      console.error('linux_deep_link_handoff_rejected', error);
    }
    try {
      const authoritative = await bridge.onboardingSnapshot();
      cacheOnboarding(authoritative);
      if (shouldRouteToOnboarding(authoritative)) {
        useShellStore.getState().setRoute('onboarding');
      } else if (hadDeepLink) {
        location.hash = requestedHash;
        useShellStore.getState().syncRouteFromHash();
      } else {
        useShellStore.getState().setRoute('overview');
      }
    } catch (error) {
      console.error('linux_onboarding_authority_unavailable', error);
      useShellStore.getState().setRoute('onboarding');
    }
  } else {
    useShellStore.getState().setRoute('onboarding');
  }
  end();

  const healthSupervisor = new DaemonHealthSupervisor(async () => {
    await useShellStore.getState().refreshHealth();
    return useShellStore.getState().health?.ok === true;
  });
  const uninstallHealthLifecycle = installDaemonHealthLifecycle(healthSupervisor);
  const subscriptionSupervisor = bridge
    ? new DaemonSubscriptionSupervisor(
        bridge,
        async (response) => {
          useShellStore.getState().recordDaemonSubscription(response);
          if (response.firstSnapshot || response.recoveredAfterRestart) {
            await useShellStore.getState().refreshHealth();
          }
        },
        {
          onStatus: (subscriptionStatus) =>
            useShellStore.getState().recordDaemonSubscriptionStatus(subscriptionStatus)
        }
      )
    : null;
  const uninstallSubscriptionLifecycle = subscriptionSupervisor
    ? installDaemonSubscriptionLifecycle(subscriptionSupervisor)
    : () => {};
  window.addEventListener('beforeunload', () => {
    uninstallSubscriptionLifecycle();
    uninstallHealthLifecycle();
  }, { once: true });
}

void boot();
