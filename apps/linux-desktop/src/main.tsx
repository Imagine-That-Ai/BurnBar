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
import { useMembershipStore } from './state/membershipStore.js';
import { NativeShellSupervisor } from './state/nativeShellSupervisor.js';
import { useShellStore } from './state/shellStore.js';
import { CompactStatusApp } from './status/CompactStatusApp.js';

async function boot(): Promise<void> {
  const end = markStart('app.start');
  applyReducedMotionClass();
  const surface = new URLSearchParams(location.search).get('surface');
  if (surface === 'status') {
    const root = document.getElementById('root');
    if (!root) throw new Error('Missing #root mount point');
    createRoot(root).render(
      <StrictMode>
        <CompactStatusApp />
      </StrictMode>
    );
    end();
    return;
  }
  const hadDeepLink = Boolean(location.hash);

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
  const bridge = useShellStore.getState().bridge;
  if (bridge) {
    try {
      const authoritative = await bridge.onboardingSnapshot();
      cacheOnboarding(authoritative);
      if (shouldRouteToOnboarding(authoritative)) {
        useShellStore.getState().setRoute('onboarding');
      } else if (!hadDeepLink) {
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

  const nativeShellSupervisor = bridge
    ? new NativeShellSupervisor(
        bridge,
        async (link) => {
          useShellStore.getState().setRoute(link.route);
          if (link.action === 'membership-success' || link.action === 'membership-cancel') {
            await useMembershipStore.getState().load();
          } else if (link.action === 'reconnect-daemon') {
            await useShellStore.getState().refreshHealth();
          }
        },
        {
          status: () => {
            const state = useShellStore.getState();
            return {
              daemonOk: state.health?.ok === true,
              online: navigator.onLine,
              lastDaemonEventAt: state.lastDaemonEventAt
            };
          }
        }
      )
    : null;
  if (nativeShellSupervisor) await nativeShellSupervisor.start();

  const healthSupervisor = new DaemonHealthSupervisor(async () => {
    await useShellStore.getState().refreshHealth();
    await nativeShellSupervisor?.refresh();
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
          await nativeShellSupervisor?.refresh();
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
    nativeShellSupervisor?.stop();
    uninstallSubscriptionLifecycle();
    uninstallHealthLifecycle();
  }, { once: true });
}

void boot();
