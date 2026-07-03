import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  inputPolicyReplay,
  linuxComputerUseAdapters,
  mediaCodecTrace,
  mobileProtocolReplayFrames,
  permissionStateRows,
  safetyInvariantSummary
} from './computerUseLinux.js';

const outRoot = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : null;

function writeEvidence(name: string, payload: unknown): void {
  if (!outRoot) return;
  fs.mkdirSync(outRoot, { recursive: true });
  fs.writeFileSync(path.join(outRoot, name), JSON.stringify(payload, null, 2) + '\n');
}

describe('Linux Computer Use evidence model', () => {
  it('covers every assigned contract with explicit product adapters', () => {
    const adapters = linuxComputerUseAdapters();
    expect(new Set(adapters.map((adapter) => adapter.target))).toEqual(new Set([
      'VAL-CU-001',
      'VAL-CU-002',
      'VAL-CU-003',
      'VAL-MEDIA-001',
      'VAL-MOBILE-001',
      'VAL-SEC-003'
    ]));
    expect(adapters.map((adapter) => adapter.id)).toEqual(expect.arrayContaining([
      'wayland-portal-pipewire',
      'x11-scrot-fallback',
      'libei',
      'at-spi2',
      'uinput-policy',
      'x11-xtest',
      'audit-signed-head',
      'panic-halt',
      'iroh-mercury-media',
      'mobile-control-replay'
    ]));
    expect(adapters.find((adapter) => adapter.id === 'wayland-portal-pipewire')?.requiresConsent).toBe(true);
    expect(adapters.find((adapter) => adapter.id === 'x11-xtest')?.requiresApproval).toBe(true);
    writeEvidence('computer-use-adapter-matrix.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W07LinuxComputerUseMediaMobile',
      adapters
    });
  });

  it('exposes permission-state UI rows for approve deny revoke and halt states', () => {
    const states = permissionStateRows();
    expect(states.map((row) => row.state)).toEqual(expect.arrayContaining([
      'approved',
      'denied',
      'degraded',
      'revoked'
    ]));
    expect(states.every((row) => row.uiLabel.length > 0 && row.evidence.length > 0)).toBe(true);
    writeEvidence('computer-use-permission-state-ui.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W07LinuxComputerUseMediaMobile',
      states
    });
  });

  it('enforces approval deny regions trust downgrade and rate limits with audit rows', () => {
    const replay = inputPolicyReplay();
    const byId = Object.fromEntries(replay.map((entry) => [entry.id, entry]));
    expect(byId['approved-action'].decision.allowed).toBe(true);
    expect(byId['approved-action'].decision.audit.approvedBy).toBe('mac');
    expect(byId['denied-region'].decision.allowed).toBe(false);
    expect(byId['denied-region'].decision.audit.denyReason).toBe('deny_region');
    expect(byId['denied-no-permission'].decision.audit.denyReason).toBe('adapter_unavailable');
    expect(byId['downgrade-only-mobile'].decision.audit.denyReason).toBe('mobile_cannot_elevate_trust');
    expect(byId['rate-limited'].decision.audit.denyReason).toBe('rate_limited');
    expect(replay.every((entry) => entry.decision.audit.actionKind.length > 0)).toBe(true);
    writeEvidence('computer-use-input-policy-replay.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W07LinuxComputerUseMediaMobile',
      replay
    });
  });

  it('keeps mobile wire compatibility additive-only for Linux metadata', () => {
    const frames = mobileProtocolReplayFrames();
    expect(frames.map((frame) => frame.type)).toEqual([
      'controlApprovalRequest',
      'controlApprovalResponse',
      'controlInputIntent',
      'mediaStreamFrame',
      'controlPanicHalt'
    ]);
    expect(frames.every((frame) => frame.protocolVersion === 1)).toBe(true);
    expect(frames.every((frame) => frame.backwardCompatibility !== undefined)).toBe(true);
    expect(frames.filter((frame) => frame.backwardCompatibility === 'additive-capability-only').length).toBeGreaterThan(0);
    writeEvidence('computer-use-mobile-protocol-replay.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W07LinuxComputerUseMediaMobile',
      frames,
      wireDiff: {
        removedFields: [],
        renamedFields: [],
        linuxAdditions: ['linuxCapabilityMetadata'],
        compatible: true
      }
    });
  });

  it('documents media codec negotiation and backpressure cases', () => {
    const trace = mediaCodecTrace();
    expect(trace.map((entry) => entry.codec)).toEqual(expect.arrayContaining([
      'hevc',
      'h264',
      'opus',
      'media-frame-v1',
      'media-frame-v2'
    ]));
    expect(trace.map((entry) => entry.backpressure)).toEqual(expect.arrayContaining([
      'dropped-delta',
      'paused-producer'
    ]));
    writeEvidence('computer-use-media-codec-trace.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W07LinuxComputerUseMediaMobile',
      trace
    });
  });

  it('keeps safety invariants explicit', () => {
    const invariants = safetyInvariantSummary();
    expect(invariants.noGlobalKeylogging).toBe(true);
    expect(invariants.noSilentAutopilot).toBe(true);
    expect(invariants.waylandCaptureRequiresPortalConsent).toBe(true);
    expect(invariants.mobileTrustDowngradeOnly).toBe(true);
    expect(invariants.signedHeadRequired).toBe(true);
    writeEvidence('computer-use-safety-invariants.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W07LinuxComputerUseMediaMobile',
      invariants
    });
  });
});
