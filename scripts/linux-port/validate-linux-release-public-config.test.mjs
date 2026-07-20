import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const SCRIPT = fileURLToPath(new URL('./validate-linux-release-public-config.mjs', import.meta.url));
const SOURCE_ROOT = path.resolve(path.dirname(SCRIPT), '../..');
const VARIABLE_NAMES = [
  'OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID',
  'OPENBURNBAR_FIREBASE_API_KEY',
  'OPENBURNBAR_LINUX_APP_CHECK_APP_ID'
];
const VALID = {
  OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID: '123456789012-desktop.apps.googleusercontent.com',
  OPENBURNBAR_FIREBASE_API_KEY: `AIza${'a'.repeat(32)}`,
  OPENBURNBAR_LINUX_APP_CHECK_APP_ID: '1:123456789012:web:abcdef1234567890'
};

function run(values = {}) {
  const env = { ...process.env };
  for (const name of VARIABLE_NAMES) delete env[name];
  Object.assign(env, values);
  return spawnSync(process.execPath, [SCRIPT], {
    cwd: SOURCE_ROOT,
    env,
    encoding: 'utf8'
  });
}

test('valid public release variables pass without echoing their values', () => {
  const result = run(VALID);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /validated\./u);
  for (const value of Object.values(VALID)) {
    assert.doesNotMatch(result.stdout, new RegExp(value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
    assert.doesNotMatch(result.stderr, new RegExp(value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
  }
});

test('missing or partial public release variables fail closed', () => {
  const missing = run();
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /Release packaging requires/u);
  const partial = run({ OPENBURNBAR_FIREBASE_API_KEY: VALID.OPENBURNBAR_FIREBASE_API_KEY });
  assert.notEqual(partial.status, 0);
  assert.match(partial.stderr, /all public identifiers together/u);
});

test('malformed public release variables fail before native work', () => {
  const cases = [
    ['OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID', 'not-an-oauth-client', /client id/u],
    ['OPENBURNBAR_FIREBASE_API_KEY', 'not-a-firebase-key', /FIREBASE_API_KEY is malformed/u],
    ['OPENBURNBAR_LINUX_APP_CHECK_APP_ID', '1:placeholder:web:bad', /APP_CHECK_APP_ID is malformed/u]
  ];
  for (const [name, value, expected] of cases) {
    const result = run({ ...VALID, [name]: value });
    assert.notEqual(result.status, 0, name);
    assert.match(result.stderr, expected, name);
    assert.doesNotMatch(result.stderr, new RegExp(value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'), name);
  }
});

test('release workflow runs the public config gate before Docker/native build', () => {
  const workflow = fs.readFileSync(path.join(SOURCE_ROOT, '.github/workflows/linux-release.yml'), 'utf8');
  const preflight = workflow.indexOf('Validate public Linux release configuration');
  const docker = workflow.indexOf('Build mission Linux toolchain image');
  const native = workflow.indexOf('Prepare unsigned native architecture artifacts');
  assert.ok(preflight >= 0, 'workflow preflight step missing');
  assert.ok(docker > preflight, 'Docker build must follow public config preflight');
  assert.ok(native > preflight, 'native build must follow public config preflight');
  assert.match(workflow.slice(preflight, docker), /validate-linux-release-public-config\.mjs/u);
  for (const name of VARIABLE_NAMES) {
    assert.match(workflow.slice(preflight, docker), new RegExp(name, 'u'));
  }
});
