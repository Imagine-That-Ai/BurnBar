import fs from 'node:fs';
import path from 'node:path';
import { describe, it, expect } from 'vitest';
import { ROUTES } from './routes.js';
import { buildDaemonRouteTranscript } from './daemonFixture.js';
import {
  automatedAccessibilityScan,
  a11yKeyboardTranscript,
  failureStateCases,
  petTierMatrix,
  onboardingFlowTranscript,
  routeAccessibilitySnapshots,
  routeSnapshotCases,
  textExpansionSafetyProof,
  tokenVisualDiff
} from './shellEvidenceModel.js';

const outRoot = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : null;

function writeEvidence(name: string, payload: unknown): void {
  if (!outRoot) return;
  fs.mkdirSync(outRoot, { recursive: true });
  fs.writeFileSync(path.join(outRoot, name), JSON.stringify(payload, null, 2) + '\n');
}

describe('shell evidence harness', () => {
  it('emits route snapshot plan for every accepted route', () => {
    const routes = routeSnapshotCases();
    expect(routes.map((route) => route.route)).toEqual(ROUTES.map((route) => route.id));
    writeEvidence('route-snapshot-plan.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      routes
    });
  });

  it('emits per-route accessibility/user-flow transcript for every accepted route', () => {
    const routes = routeAccessibilitySnapshots();
    expect(routes.map((route) => route.route)).toEqual(ROUTES.map((route) => route.id));
    writeEvidence('route-a11y-user-flow-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      mode: 'route-dom-a11y-oracle',
      routes
    });
  });

  it('emits automated accessibility scan artifact', () => {
    const checks = automatedAccessibilityScan();
    expect(checks.every((check) => check.result === 'pass')).toBe(true);
    writeEvidence('automated-a11y-scan.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'static-dom-contract-scan',
      checks
    });
  });

  it('emits a11y keyboard transcript artifact', () => {
    const steps = a11yKeyboardTranscript();
    expect(steps.length).toBeGreaterThan(5);
    writeEvidence('a11y-keyboard-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'dom-model-transcript',
      steps
    });
  });

  it('emits token visual diff artifact', () => {
    const diff = tokenVisualDiff();
    expect(diff.changed.length).toBeGreaterThan(0);
    writeEvidence('token-visual-diff.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      breakpoints: ['default', 'max-width:960px'],
      skins: ['editorial', 'aurora'],
      ...diff
    });
  });

  it('emits failure state transcript', () => {
    const cases = failureStateCases();
    expect(cases.map((c) => c.id)).toEqual(
      expect.arrayContaining([
        'daemon-offline',
        'tray-degraded',
        'secret-store-unavailable',
        'network-offline',
        'permission-denied',
        'quota-exhausted',
        'update-channel-unavailable',
        'text-expansion-no-consent'
      ])
    );
    writeEvidence('failure-state-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      cases
    });
  });

  it('emits pet tier matrix and text expansion safety proof artifacts', () => {
    const pet = petTierMatrix();
    expect(pet).toHaveLength(3);
    writeEvidence('pet-tier-matrix.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      pet
    });
    const textExpansion = textExpansionSafetyProof();
    expect(textExpansion.globalCapture).toBe(false);
    writeEvidence('text-expansion-safety-proof.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      textExpansion
    });
  });

  it('emits onboarding skip retry resume transcript', () => {
    const steps = onboardingFlowTranscript();
    expect(steps.map((step) => step.action)).toEqual([
      'first-run',
      'retry-check',
      'skip-step',
      'restart-resume',
      'complete'
    ]);
    writeEvidence('onboarding-flow-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'first-run-localStorage-state-machine',
      steps
    });
  });

  it('emits daemon route data-oracle transcript', () => {
    const routes = ROUTES.filter((r) => r.group === 'dashboard').map((r) => r.id);
    const daemon = {
      ok: true,
      protocolVersion: 1,
      daemonVersion: 'gui-session-fake-daemon-0.1.0',
      socketPath: '$XDG_DATA_HOME/openburnbar/openburnbar-daemon.sock',
      gatewayEnabled: true,
      gatewayHost: '127.0.0.1',
      gatewayPort: 47877
    };
    const transcript = buildDaemonRouteTranscript(routes, daemon);
    writeEvidence('daemon-route-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      mode: 'daemon-backed-oracle',
      daemon,
      routes: transcript
    });
  });
});
