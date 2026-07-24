// @vitest-environment jsdom
import fs from 'node:fs';
import path from 'node:path';
import { act, cleanup, render } from '@testing-library/react';
import axe, { type Result } from 'axe-core';
import { afterAll, describe, expect, it } from 'vitest';
import { App } from '../app/App.js';
import { ROUTES, type ShellRoute } from '../routes.js';
import { useShellStore } from '../state/shellStore.js';
import { makeAvailableRuntimeCapabilityManifest } from '../testing/bridgeStubs.js';
import type { LinuxShellBridge } from '../tauriBridge.js';

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

    const failures = auditRows.filter((row) => row.violationCount > 0);
    expect(failures, JSON.stringify(failures, null, 2)).toEqual([]);
  }, 60_000);
});
