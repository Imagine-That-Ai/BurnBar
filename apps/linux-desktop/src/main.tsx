import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { applyReducedMotionClass } from './a11y.js';
import { App } from './app/App.js';
import {
  cacheOnboarding,
  shouldRouteToOnboarding
} from './onboardingStore.js';
import { markStart } from './perfMarks.js';
import { shellDestinationFromNative } from './routes.js';
import { DaemonHealthSupervisor, installDaemonHealthLifecycle } from './state/daemonHealthSupervisor.js';
import {
  DaemonSubscriptionSupervisor,
  installDaemonSubscriptionLifecycle
} from './state/daemonSubscriptionSupervisor.js';
import { useShellStore } from './state/shellStore.js';
import { isPetCompanionWindow } from './petCompanionWindow.js';

async function boot(): Promise<void> {
  const end = markStart('app.start');
  const removeReducedMotionListener = applyReducedMotionClass();
  const chatPopout = new URLSearchParams(location.search).get('window') === 'chat-popout';
  const petCompanion = isPetCompanionWindow();
  const requestedHash = location.hash;
  const hadDeepLink = chatPopout || petCompanion || Boolean(requestedHash && requestedHash !== '#/onboarding');

  if (petCompanion) document.documentElement.classList.add('pet-companion-window');

  // First run lands on the onboarding wizard unless a deep link is present.
  if (!chatPopout && !petCompanion && location.hash !== '#/onboarding') {
    location.hash = '#/onboarding';
    useShellStore.getState().syncRouteFromHash({ measure: false });
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
  if (chatPopout) {
    useShellStore.getState().setRoute('chat', { measure: false });
  } else if (petCompanion) {
    useShellStore.getState().setRoute('pet', { measure: false });
  }
  if (bridge) {
    try {
      const authoritative = await bridge.onboardingSnapshot();
      const nativeDeepLink = bridge.initialDeepLinkRoute
        ? await bridge.initialDeepLinkRoute()
        : null;
      const requestedNativeDestination = nativeDeepLink
        ? shellDestinationFromNative(nativeDeepLink)
        : null;
      cacheOnboarding(authoritative);
      if (chatPopout) {
        useShellStore.getState().setRoute('chat', { measure: false });
      } else if (petCompanion) {
        useShellStore.getState().setRoute('pet', { measure: false });
      } else if (requestedNativeDestination) {
        location.hash = requestedNativeDestination.hash;
        useShellStore.getState().syncRouteFromHash({ measure: false });
      } else if (shouldRouteToOnboarding(authoritative)) {
        useShellStore.getState().setRoute('onboarding', { measure: false });
      } else if (hadDeepLink) {
        location.hash = requestedHash;
        useShellStore.getState().syncRouteFromHash({ measure: false });
      } else {
        useShellStore.getState().setRoute('overview', { measure: false });
      }
    } catch (error) {
      console.error('linux_onboarding_authority_unavailable', error);
      useShellStore.getState().setRoute('onboarding', { measure: false });
    }
  } else {
    if (!chatPopout && !petCompanion) useShellStore.getState().setRoute('onboarding', { measure: false });
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
    removeReducedMotionListener();
    if (petCompanion) document.documentElement.classList.remove('pet-companion-window');
    uninstallSubscriptionLifecycle();
    uninstallHealthLifecycle();
  }, { once: true });
}

void boot();
