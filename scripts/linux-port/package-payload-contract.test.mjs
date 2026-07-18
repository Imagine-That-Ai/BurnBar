/**
 * Drives real package artifacts (when present) and smoke summary for product-parity packaging.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.join(root, 'docs/linux-port/evidence/mission-002-reanchor');
const artDir = path.join(outDir, 'artifacts');

function listDeb(file) {
  const r = spawnSync('dpkg-deb', ['--contents', file], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout : null;
}
function listRpm(file) {
  const r = spawnSync('rpm', ['-qlp', file], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout : null;
}

test('smoke summary is green when present', () => {
  const p = path.join(outDir, 'smoke/package-smoke-summary.json');
  assert.ok(fs.existsSync(p), 'package-smoke-summary.json missing');
  const s = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.equal(s.passed, true);
  assert.equal(s.failedCount, 0);
});

const debArtifact = path.join(artDir, 'OpenBurnBar_0.1.0_arm64.deb');
const rpmArtifact = path.join(artDir, 'OpenBurnBar-0.1.0-1.aarch64.rpm');

test('deb artifact ships daemon, launch, Swift, and SQLCipher runtime', {
  skip: !fs.existsSync(debArtifact)
    ? 'historical DEB evidence artifact is external and was not supplied to this checkout'
    : false
}, () => {
  const deb = debArtifact;
  assert.ok(fs.existsSync(deb), 'deb missing');
  assert.ok(fs.statSync(deb).size > 40_000_000, 'deb too small to contain daemon+runtime');
  const listing = listDeb(deb);
  if (listing === null) {
    // Host without dpkg-deb: rely on smoke log produced on Linux guest.
    const log = fs.readFileSync(path.join(outDir, 'smoke/package-install-uninstall.log'), 'utf8');
    assert.match(log, /assert deb contains openburnbar-daemon-launch[\s\S]*?exit_code=0/);
    assert.match(log, /usr\/lib\/openburnbar\/swift/);
    assert.match(log, /usr\/lib\/openburnbar\/native\/libsqlcipher\.so\.0/);
    assert.match(log, /usr\/lib\/openburnbar\/native\/libopenburnbar_iroh\.so/);
    assert.match(log, /usr\/bin\/OpenBurnBarCore_OpenBurnBarCore\.resources/);
    return;
  }
  assert.match(listing, /openburnbar-daemon-launch/);
  assert.match(listing, /usr\/bin\/openburnbar-daemon/);
  assert.match(listing, /usr\/lib\/openburnbar\/swift/);
  assert.match(listing, /usr\/lib\/openburnbar\/native\/libsqlcipher\.so\.0/);
  assert.match(listing, /usr\/lib\/openburnbar\/native\/libopenburnbar_iroh\.so/);
  assert.match(listing, /usr\/bin\/OpenBurnBarCore_OpenBurnBarCore\.resources/);
});

test('rpm artifact ships daemon, launch, Swift, and SQLCipher runtime', {
  skip: !fs.existsSync(rpmArtifact)
    ? 'historical RPM evidence artifact is external and was not supplied to this checkout'
    : false
}, () => {
  const rpm = rpmArtifact;
  assert.ok(fs.existsSync(rpm), 'rpm missing');
  assert.ok(fs.statSync(rpm).size > 40_000_000, 'rpm too small to contain daemon+runtime');
  const listing = listRpm(rpm);
  if (listing === null) {
    const log = fs.readFileSync(path.join(outDir, 'smoke/package-install-uninstall.log'), 'utf8');
    assert.match(log, /assert rpm contains openburnbar-daemon-launch[\s\S]*?exit_code=0/);
    assert.match(log, /usr\/lib\/openburnbar\/swift/);
    assert.match(log, /usr\/lib\/openburnbar\/native\/libsqlcipher\.so\.0/);
    assert.match(log, /usr\/lib\/openburnbar\/native\/libopenburnbar_iroh\.so/);
    assert.match(log, /usr\/bin\/OpenBurnBarCore_OpenBurnBarCore\.resources/);
    return;
  }
  assert.match(listing, /openburnbar-daemon-launch/);
  assert.match(listing, /openburnbar-daemon/);
  assert.match(listing, /usr\/lib\/openburnbar\/swift/);
  assert.match(listing, /usr\/lib\/openburnbar\/native\/libsqlcipher\.so\.0/);
  assert.match(listing, /usr\/lib\/openburnbar\/native\/libopenburnbar_iroh\.so/);
  assert.match(listing, /usr\/bin\/OpenBurnBarCore_OpenBurnBarCore\.resources/);
});

test('VAL-DASHBOARD-004 six-layout screenshots exist', () => {
  const dir = path.join(outDir, 'dashboard-layouts');
  for (const id of ['classic','aurora','nebula','constellation','cockpit','atelier']) {
    const f = path.join(dir, `layout-${id}.png`);
    assert.ok(fs.existsSync(f), f);
    assert.ok(fs.statSync(f).size > 1000, f+' tiny');
  }
  assert.ok(fs.existsSync(path.join(dir, 'all-layouts-matrix.png')));
  const md = fs.readFileSync(path.join(dir, 'VAL-DASHBOARD-004.md'), 'utf8');
  assert.match(md, /VAL-DASHBOARD-004/);
});
