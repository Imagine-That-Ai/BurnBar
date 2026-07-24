import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const helper = path.join(repoRoot, 'packaging/linux/openburnbar-cli-migrate.sh');

test('package post-install registers the user daemon service before migration exits', () => {
  const source = fs.readFileSync(helper, 'utf8');
  const enableCall = source.indexOf('systemctl --global enable openburnbar-daemon.service');
  const canonicalGuard = source.indexOf('if [[ ! -f "$canonical" || ! -x "$canonical" ]]');
  assert.ok(enableCall >= 0, 'maintainer script must enable the package-owned user service');
  assert.ok(canonicalGuard > enableCall, 'service registration must not be skipped by CLI migration early returns');
  assert.match(source, /command -v systemctl/u);
  assert.match(source, /leaving package installed/u);
});

test('systemd service keeps /proc peer authentication visible to external clients', () => {
  const service = fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/openburnbar-daemon.service'),
    'utf8'
  );
  const aurService = fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/aur/openburnbar-daemon.service'),
    'utf8'
  );
  assert.equal(aurService, service, 'AUR service must mirror the canonical unit');
  assert.doesNotMatch(service, /^PrivateTmp=/mu);
  assert.doesNotMatch(service, /^Protect(Home|System|Proc)=/mu);
  assert.doesNotMatch(service, /^Read(?:Only|Write|WriteOnly)Paths=/mu);
  assert.match(service, /SO_PEERCRED plus \/proc\/<pid>\/exe/u);
});

function makeRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-cli-migration-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'usr/bin'), { recursive: true });
  fs.mkdirSync(path.join(root, 'usr/local/bin'), { recursive: true });
  return root;
}

function runHelper(root) {
  return spawnSync('bash', [helper, '--root', root, 'configure'], {
    encoding: 'utf8',
    env: { ...process.env, OPENBURNBAR_PACKAGE_VERSION: '9.9.9' }
  });
}

test('moves an unmanaged stale CLI to a versioned backup without deleting it', (t) => {
  const root = makeRoot(t);
  const canonical = path.join(root, 'usr/bin/openburnbar-cli');
  const legacy = path.join(root, 'usr/local/bin/openburnbar-cli');
  fs.writeFileSync(canonical, 'current-cli');
  fs.chmodSync(canonical, 0o755);
  fs.writeFileSync(legacy, 'stale-cli');
  fs.chmodSync(legacy, 0o755);
  const existing = `${legacy}.openburnbar-legacy-9.9.9`;
  fs.writeFileSync(existing, 'older-backup');

  const result = runHelper(root);
  assert.equal(result.status, 0, result.stderr);
  const backup = `${existing}.1`;
  assert.equal(fs.existsSync(legacy), false);
  assert.equal(fs.readFileSync(canonical, 'utf8'), 'current-cli');
  assert.equal(fs.readFileSync(backup, 'utf8'), 'stale-cli');
  assert.equal(fs.readFileSync(existing, 'utf8'), 'older-backup');
  assert.match(result.stdout, /moved unmanaged CLI/u);
});

test('leaves an identical current binary and a symlink to it untouched', (t) => {
  const root = makeRoot(t);
  const canonical = path.join(root, 'usr/bin/openburnbar-cli');
  const legacy = path.join(root, 'usr/local/bin/openburnbar-cli');
  fs.writeFileSync(canonical, 'current-cli');
  fs.chmodSync(canonical, 0o755);
  fs.writeFileSync(legacy, 'current-cli');
  fs.chmodSync(legacy, 0o755);
  assert.equal(runHelper(root).status, 0);
  assert.equal(fs.readFileSync(legacy, 'utf8'), 'current-cli');

  fs.rmSync(legacy);
  fs.symlinkSync('../../../usr/bin/openburnbar-cli', legacy);
  assert.equal(runHelper(root).status, 0);
  assert.equal(fs.readlinkSync(legacy), '../../../usr/bin/openburnbar-cli');
});

test('moves an identical but non-executable legacy file so it cannot shadow the package CLI', (t) => {
  const root = makeRoot(t);
  const canonical = path.join(root, 'usr/bin/openburnbar-cli');
  const legacy = path.join(root, 'usr/local/bin/openburnbar-cli');
  fs.writeFileSync(canonical, 'current-cli');
  fs.chmodSync(canonical, 0o755);
  fs.writeFileSync(legacy, 'current-cli');
  fs.chmodSync(legacy, 0o644);

  const result = runHelper(root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(legacy), false);
  assert.equal(
    fs.readFileSync(`${legacy}.openburnbar-legacy-9.9.9`, 'utf8'),
    'current-cli'
  );
});

test('leaves non-regular legacy paths untouched', (t) => {
  const root = makeRoot(t);
  const canonical = path.join(root, 'usr/bin/openburnbar-cli');
  const legacy = path.join(root, 'usr/local/bin/openburnbar-cli');
  fs.writeFileSync(canonical, 'current-cli');
  fs.chmodSync(canonical, 0o755);
  fs.mkdirSync(legacy);
  fs.writeFileSync(path.join(legacy, 'user-data'), 'keep');

  const result = runHelper(root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(legacy, 'user-data')), true);
  assert.match(result.stderr, /non-regular path untouched/u);
});
