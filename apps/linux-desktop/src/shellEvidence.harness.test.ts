import fs from 'node:fs';
import path from 'node:path';
import { describe, it, expect } from 'vitest';
import { ROUTES } from './routes.js';
import { buildDaemonRouteTranscript } from './daemonFixture.js';
import {
  a11yKeyboardTranscript,
  failureStateCases,
  tokenVisualDiff
} from './shellEvidenceModel.js';
import {
  SHELL_EVIDENCE_JSON_ARTIFACTS,
  buildAllShellEvidenceJsonPayloads
} from './shellEvidenceArtifacts.js';

const outRoot = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : null;

function writeEvidence(name: string, payload: unknown): void {
  if (!outRoot) return;
  fs.mkdirSync(outRoot, { recursive: true });
  fs.writeFileSync(path.join(outRoot, name), JSON.stringify(payload, null, 2) + '\n');
}

describe('shell evidence harness', () => {
  it('emits required route and policy JSON artifacts', () => {
    const generatedAt = new Date().toISOString();
    const payloads = buildAllShellEvidenceJsonPayloads(generatedAt);
    for (const name of SHELL_EVIDENCE_JSON_ARTIFACTS) {
      if (name in payloads) {
        writeEvidence(name, payloads[name as keyof typeof payloads]);
      }
    }
    for (const name of SHELL_EVIDENCE_JSON_ARTIFACTS) {
      if (!(name in payloads)) continue;
      if (!outRoot) continue;
      expect(fs.existsSync(path.join(outRoot, name))).toBe(true);
    }
  });

  it('emits a11y keyboard transcript artifact', () => {
    const steps = a11yKeyboardTranscript();
    expect(steps.length).toBeGreaterThan(5);
    writeEvidence('a11y-keyboard-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'dom-model-transcript',
      surface: 'host-vitest',
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
    writeEvidence('failure-state-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      surface: 'host-vitest',
      cases
    });
  });

  it('emits daemon route fixture transcript', () => {
    const routes = ROUTES.filter((r) => r.group === 'dashboard').map((r) => r.id);
    const transcript = buildDaemonRouteTranscript(routes);
    writeEvidence('daemon-route-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      mode: 'fixture',
      surface: 'host-vitest',
      validatorGuidance:
        'Dashboard route rows are fixture-backed DOM transcripts; live daemon-backed routes require OpenBurnBarDaemon AF_UNIX proof from the packaged session oracle.',
      routes: transcript
    });
  });
});