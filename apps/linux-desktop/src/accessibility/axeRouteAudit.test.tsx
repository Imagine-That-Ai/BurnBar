// @vitest-environment jsdom
import fs from 'node:fs';
import path from 'node:path';
import { act, cleanup, render } from '@testing-library/react';
import axe, { type Result } from 'axe-core';
import { afterAll, describe, expect, it } from 'vitest';
import { App } from '../app/App.js';
import { ROUTES, type ShellRoute } from '../routes.js';
import { useShellStore } from '../state/shellStore.js';
import { resetAccountStoreForTests, useAccountStore } from '../state/accountStore.js';
import {
  resetProviderExternalAuthStoreForTests,
  useProviderExternalAuthStore
} from '../state/providerExternalAuthStore.js';
import { useSystemStore } from '../state/systemStore.js';
import { bridgeStubDefaults, makeAvailableRuntimeCapabilityManifest } from '../testing/bridgeStubs.js';
import type { LinuxShellBridge, ProviderExternalAuthFlowSnapshot } from '../tauriBridge.js';
import { fixtureConfigSnapshot } from '../daemonFixture.js';
import { SETTINGS_TAB_STORAGE_KEY } from '../surfaces/settings/settingsTabs.js';

type AuditRow = {
  state: string;
  route: ShellRoute;
  violationCount: number;
  violations: Array<Pick<Result, 'id' | 'impact' | 'help' | 'helpUrl' | 'nodes'>>;
};

const auditRows: AuditRow[] = [];
const evidenceRoot = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : null;

function resetShell(route: ShellRoute): void {
  localStorage.clear();
  location.hash = `#/${route}`;
  useShellStore.setState({
    route,
    health: null,
    healthError: null,
    healthBusy: false,
    trayDegraded: false,
    bridge: null,
    bridgeReady: true,
    runtimeCapabilities: null,
    capabilityError: null,
    fixtureMode: true
  });
}

async function auditState(state: string, route: ShellRoute): Promise<AuditRow> {
  const rendered = render(<App />);
  await act(async () => {
    await new Promise((resolve) => window.setTimeout(resolve, 0));
  });
  const results = await axe.run(rendered.container, {
    resultTypes: ['violations'],
    rules: {
      // jsdom has no layout or paint engine. Contrast remains a packaged-session check.
      'color-contrast': { enabled: false }
    }
  });
  const row: AuditRow = {
    state,
    route,
    violationCount: results.violations.length,
    violations: results.violations.map((violation) => ({
      id: violation.id,
      impact: violation.impact,
      help: violation.help,
      helpUrl: violation.helpUrl,
      nodes: violation.nodes
    }))
  };
  rendered.unmount();
  cleanup();
  return row;
}

afterAll(() => {
  if (!evidenceRoot) return;
  fs.mkdirSync(evidenceRoot, { recursive: true });
  fs.writeFileSync(
    path.join(evidenceRoot, 'axe-route-accessibility-scan.json'),
    `${JSON.stringify({
      generatedAt: new Date().toISOString(),
      method: 'axe-core-jsdom-route-and-capability-state-matrix',
      axeVersion: axe.version,
      colorContrast: 'separately verified on the packaged desktop because jsdom has no layout engine',
      allPass: auditRows.every((row) => row.violationCount === 0),
      states: auditRows
    }, null, 2)}\n`
  );
});

describe('axe route accessibility audit', () => {
  it('reports no semantic violations across every route and capability boundary state', async () => {
    for (const route of ROUTES) {
      resetShell(route.id);
      auditRows.push(await auditState('browser-preview', route.id));
    }

    const unavailable = makeAvailableRuntimeCapabilityManifest();
    const mercury = unavailable.capabilities.find((entry) => entry.id === 'media.mercury');
    if (!mercury) throw new Error('media.mercury missing from test manifest');
    mercury.state = 'unavailable';
    mercury.reason = 'Media transport is unavailable.';
    mercury.substitute = 'Use a paired supported peer.';
    resetShell('mercury');
    useShellStore.setState({
      bridge: {} as LinuxShellBridge,
      runtimeCapabilities: unavailable,
      fixtureMode: false
    });
    auditRows.push(await auditState('capability-unavailable', 'mercury'));

    const degraded = makeAvailableRuntimeCapabilityManifest();
    const pet = degraded.capabilities.find((entry) => entry.id === 'pet.overlay');
    if (!pet) throw new Error('pet.overlay missing from test manifest');
    pet.state = 'degraded';
    pet.reason = 'Input pass-through is unavailable.';
    pet.substitute = 'Use the contained draggable surface.';
    resetShell('pet');
    useShellStore.setState({
      bridge: {} as LinuxShellBridge,
      runtimeCapabilities: degraded,
      fixtureMode: false
    });
    auditRows.push(await auditState('capability-degraded', 'pet'));

    const pendingAccount = {
      state: 'authorization_pending' as const,
      signedIn: false,
      trustClass: 'linux-lower-trust' as const,
      syncState: 'local-only' as const,
      updatedAt: new Date().toISOString(),
      session: {
        flowId: 'axe-flow',
        userCode: 'ABCD-EFGH',
        verificationUrl: 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH',
        expiresAt: new Date(Date.now() + 60_000).toISOString(),
        pollIntervalSeconds: 5
      }
    };
    resetShell('account');
    useAccountStore.setState({ data: pendingAccount, authPhase: 'pending', authSession: pendingAccount.session });
    useShellStore.setState({
      bridge: {
        ...bridgeStubDefaults,
        accountStatus: async () => pendingAccount,
        accountDeviceAuthPoll: async () => pendingAccount
      } as unknown as LinuxShellBridge,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      fixtureMode: false
    });
    auditRows.push(await auditState('account-authorization-pending', 'account'));
    resetAccountStoreForTests();

    const providerAuthFlow = (
      state: 'awaiting_user' | 'failed'
    ): ProviderExternalAuthFlowSnapshot => ({
      flowId: 'axe-provider-flow',
      providerId: 'openai',
      providerDisplayName: 'OpenAI',
      authMethodId: 'openai-codex-oauth',
      authMethodDisplayName: 'Sign in with OpenAI / Codex',
      cliDisplayName: 'Codex',
      state,
      availability: 'available',
      cliInstalled: true,
      connected: false,
      problem: state === 'failed' ? {
        code: 'verification_failed',
        message: 'Codex sign-in could not be verified. Try again.',
        recoverable: true
      } : undefined,
      startedAt: '2026-07-10T12:00:00.000Z',
      updatedAt: '2026-07-10T12:00:10.000Z',
      expiresAt: state === 'awaiting_user' ? '2026-07-10T12:05:00.000Z' : undefined,
      completedAt: state === 'failed' ? '2026-07-10T12:00:10.000Z' : undefined
    });
    const config = fixtureConfigSnapshot();
    for (const providerState of ['awaiting_user', 'failed'] as const) {
      resetShell('settings');
      localStorage.setItem(SETTINGS_TAB_STORAGE_KEY, 'agents');
      useSystemStore.setState({ config, loading: false, error: null });
      const snapshot = providerAuthFlow(providerState);
      useProviderExternalAuthStore.setState({ snapshots: { openai: snapshot } });
      useShellStore.setState({
        bridge: {
          ...bridgeStubDefaults,
          configSnapshot: async () => config,
          accountStatus: async () => ({
            state: 'signed_out',
            signedIn: false,
            trustClass: 'linux-lower-trust',
            syncState: 'local-only',
            updatedAt: '2026-07-10T12:00:00.000Z'
          }),
          providerExternalAuthStatus: async () => snapshot
        } as unknown as LinuxShellBridge,
        runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
        fixtureMode: false
      });
      auditRows.push(await auditState(`provider-auth-${providerState}`, 'settings'));
      resetProviderExternalAuthStoreForTests();
    }

    const failures = auditRows.filter((row) => row.violationCount > 0);
    expect(failures, JSON.stringify(failures, null, 2)).toEqual([]);
  }, 30_000);
});
