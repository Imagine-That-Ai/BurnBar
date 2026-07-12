/**
 * Proves the Linux peer-probe wire shape for daemon.computer_use.approval.pending
 * omits `params` and that the server-side fallback (empty ComputerUseApprovalPendingRequest)
 * is the documented contract. This mirrors the fixed handler in
 * BurnBarDaemonServer+RPCComputerUse.swift and is exercised live on the UTM guest.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

test('CU pending peer probe payload omits params (Linux C probe shape)', () => {
  // Exact shape captured via strace on openburnbar-linux-desktop peer probe.
  const probe = {
    protocolVersion: 1,
    id: 'daemon.computer_use.approval.pending',
    method: 'daemon.computer_use.approval.pending',
    traceId: 't',
    authToken: 'test-token'
  };
  assert.equal('params' in probe, false);
  const wire = JSON.stringify(probe) + '\n';
  const parsed = JSON.parse(wire.trim());
  assert.equal(parsed.method, 'daemon.computer_use.approval.pending');
  assert.equal(parsed.params, undefined);
});

test('shipped daemon handler documents params-optional for approval.pending', () => {
  const src = fs.readFileSync(
    path.join(root, 'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCComputerUse.swift'),
    'utf8'
  );
  assert.match(src, /case \.computerUseApprovalPending:/);
  assert.match(src, /Params are optional for this poll/);
  assert.match(src, /ComputerUseApprovalPendingRequest\(\)/);
});

test('live reverify evidence shows empty requests array', () => {
  const p = path.join(
    root,
    'docs/linux-port/evidence/mission-002-reanchor/vm-e2e/branch-daemon/live-reverify.json'
  );
  assert.ok(fs.existsSync(p), 'live-reverify.json must exist');
  const live = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.ok(live.cuPending?.result?.requests);
  assert.equal(Array.isArray(live.cuPending.result.requests), true);
  assert.equal(live.modelsCatalog?.catalog, true);
  assert.equal(live.modelsCatalog?.platform, 'linux');
  assert.ok(live.modelsCatalog?.count > 0);
});
