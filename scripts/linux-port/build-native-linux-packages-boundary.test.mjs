import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const signer = path.join(repoRoot, 'scripts/linux-port/build-native-linux-packages.mjs');

test('legacy native-signing key environment is rejected before any child executes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-env-reject-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  const result = spawnSync(process.execPath, [signer, '--private-key-stdin', '--version', '1.2.3'], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: 'environment-secret-must-not-leak'
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /is forbidden/u);
  assert.doesNotMatch(result.stdout + result.stderr, /environment-secret-must-not-leak/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});
