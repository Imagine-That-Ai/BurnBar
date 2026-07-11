import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const sourceScript = path.join(repoRoot, 'scripts/setup-linux-downloads-r2.sh');
const requiredEnvironment = [
  'CLOUDFLARE_API_TOKEN',
  'CLOUDFLARE_ACCOUNT_ID',
  'OPENBURNBAR_R2_BUCKET',
  'OPENBURNBAR_R2_CUSTOM_DOMAIN',
  'OPENBURNBAR_R2_ZONE_ID',
  'OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN',
  'OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN'
];

test('setup requires an explicit mode before package or cloud access', () => {
  const fixture = createFixture();
  try {
    const result = runSetup(fixture, validEnvironment(fixture));
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /accepts only --provision-only, --deploy-only, or --feed-only/u);
    assert.equal(fs.readFileSync(fixture.log, 'utf8'), '');
  } finally {
    fixture.cleanup();
  }
});

test('setup fails closed before package or cloud access when mode requirements are absent', () => {
  const fixture = createFixture();
  try {
    for (const mode of ['--provision-only', '--deploy-only']) {
      const required = mode === '--provision-only' ? requiredEnvironment : requiredEnvironment.slice(0, 5);
      for (const missing of required) {
      fs.writeFileSync(fixture.log, '');
      const env = validEnvironment(fixture);
      delete env[missing];
        const result = runSetup(fixture, env, [mode]);
      assert.notEqual(result.status, 0, missing);
      assert.match(result.stderr, new RegExp(`missing: ${missing}`), missing);
      assert.equal(fs.readFileSync(fixture.log, 'utf8'), '', `${missing} must fail before npm or Wrangler`);
      }
    }
  } finally {
    fixture.cleanup();
  }
});

test('provision creates once, inspects idempotently, and deploys distinct permanent control planes', () => {
  const fixture = createFixture();
  try {
    const env = validEnvironment(fixture);
    const first = runSetup(fixture, env, ['--provision-only']);
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
    const second = runSetup(fixture, env, ['--provision-only']);
    assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);

    const lines = fs.readFileSync(fixture.log, 'utf8').trim().split('\n');
    assert.equal(lines.filter((line) => line === 'npm ci --prefix WORKER --ignore-scripts --no-audit --no-fund').length, 2);
    assert.equal(lines.filter((line) => line === 'wrangler r2 bucket create').length, 1);
    assert.equal(lines.filter((line) => line === 'wrangler r2 bucket domain add').length, 1);
    assert.equal(lines.filter((line) => line === 'wrangler deploy wrangler-upload.jsonc secret-ok mode-600').length, 2);
    assert.equal(lines.filter((line) => line === 'wrangler deploy wrangler-control.jsonc secret-ok mode-600').length, 2);
    assert.equal(lines.some((line) => line.startsWith('wrangler deploy wrangler.jsonc')), false);
    assert.ok(lines.filter((line) => line === 'wrangler r2 bucket info').length >= 4);
    assert.ok(lines.filter((line) => line === 'wrangler r2 bucket domain get').length >= 3);
    assert.equal(lines.filter((line) => line.startsWith('curl guard ')).length, 14);
    const firstUpload = lines.indexOf('wrangler deploy wrangler-upload.jsonc secret-ok mode-600');
    const firstControl = lines.indexOf('wrangler deploy wrangler-control.jsonc secret-ok mode-600');
    const firstDomainAdd = lines.indexOf('wrangler r2 bucket domain add');
    const firstGuard = lines.findIndex((line) => line.startsWith('curl guard '));
    assert.ok(firstUpload < firstControl && firstControl < firstDomainAdd && firstDomainAdd < firstGuard);
    for (const line of lines.filter((value) => value.startsWith('curl guard '))) {
      assert.match(line, / no-auth retries=30$/u);
    }
    for (const guardedPath of [
      '/linux/repository-activations/stable.json',
      '/linux/repository-activations/prerelease.json',
      '/linux/repository-activations/nightly.json',
      '/linux/update-feed-activation.json',
      '/linux/update-feed-activations/stable.json',
      '/linux/update-feed-activations/prerelease.json',
      '/linux/update-feed-activations/nightly.json'
    ]) {
      assert.equal(lines.filter((line) => line === `curl guard ${guardedPath} no-auth retries=30`).length, 2);
    }
    assert.equal(lines.some((line) => /r2\.dev|dev-url/u.test(line)), false);
    assert.equal(lines.some((line) => line.includes(env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN)), false);
    assert.equal(lines.some((line) => line.includes(env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN)), false);
    for (const secret of [env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN, env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN]) {
      assert.equal(first.stdout.includes(secret) || first.stderr.includes(secret), false);
      assert.equal(second.stdout.includes(secret) || second.stderr.includes(secret), false);
    }
  } finally {
    fixture.cleanup();
  }
});

test('provision rejects a raw-bucket 404 because it does not prove the control Worker owns pointer routes', () => {
  const fixture = createFixture();
  try {
    const result = runSetup(fixture, {
      ...validEnvironment(fixture),
      FAKE_GUARD_MODE: 'raw-bucket-404'
    }, ['--provision-only']);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /did not receive the Worker-owned 404/u);
    const lines = fs.readFileSync(fixture.log, 'utf8').trim().split('\n');
    assert.ok(lines.indexOf('wrangler deploy wrangler-control.jsonc secret-ok mode-600')
      < lines.indexOf('wrangler r2 bucket domain add'));
    assert.ok(lines.indexOf('wrangler r2 bucket domain add')
      < lines.findIndex((line) => line.startsWith('curl guard ')));
  } finally {
    fixture.cleanup();
  }
});

test('provision rejects a shared upload and activation credential before cloud access', () => {
  const fixture = createFixture();
  try {
    const environment = validEnvironment(fixture);
    environment.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN = environment.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN;
    const result = runSetup(fixture, environment, ['--provision-only']);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /upload and activation tokens must be distinct/u);
    assert.equal(fs.readFileSync(fixture.log, 'utf8'), '');
  } finally {
    fixture.cleanup();
  }
});

test('deploy-only exposes serving routes without repository credentials or provisioning access', () => {
  const fixture = createFixture();
  try {
    const deployEnvironment = validEnvironment(fixture);
    delete deployEnvironment.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN;
    delete deployEnvironment.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN;
    const deploy = runSetup(fixture, deployEnvironment, ['--deploy-only']);
    assert.equal(deploy.status, 0, `${deploy.stdout}\n${deploy.stderr}`);
    const lines = fs.readFileSync(fixture.log, 'utf8').trim().split('\n');
    assert.ok(lines.includes('wrangler deploy wrangler.jsonc no-secrets'));
    assert.equal(lines.some((line) => line.includes('wrangler-upload.jsonc')), false);
    assert.equal(lines.some((line) => line.includes('wrangler-control.jsonc')), false);
    assert.equal(lines.some((line) => line.startsWith('wrangler r2 bucket')), false);
  } finally {
    fixture.cleanup();
  }
});

test('feed-only exposes root feed routes without repository credentials or provisioning access', () => {
  const fixture = createFixture();
  try {
    const environment = validEnvironment(fixture);
    delete environment.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN;
    delete environment.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN;
    const result = runSetup(fixture, environment, ['--feed-only']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const lines = fs.readFileSync(fixture.log, 'utf8').trim().split('\n');
    assert.ok(lines.includes('wrangler deploy wrangler-feed.jsonc no-secrets'));
    assert.equal(lines.some((line) => line.includes('wrangler-upload.jsonc')), false);
    assert.equal(lines.some((line) => line.includes('wrangler-control.jsonc')), false);
    assert.equal(lines.some((line) => line.startsWith('wrangler r2 bucket')), false);
  } finally {
    fixture.cleanup();
  }
});

test('setup rejects deployment contract drift before touching npm or Cloudflare', () => {
  for (const mutate of [
    (fixture) => {
      const config = JSON.parse(fs.readFileSync(fixture.config, 'utf8'));
      config.r2_buckets[0].bucket_name = 'wrong-bucket';
      fs.writeFileSync(fixture.config, `${JSON.stringify(config, null, 2)}\n`);
    },
    (fixture) => {
      const lock = JSON.parse(fs.readFileSync(fixture.lock, 'utf8'));
      lock.packages['node_modules/wrangler'].version = '4.109.0';
      fs.writeFileSync(fixture.lock, `${JSON.stringify(lock, null, 2)}\n`);
    },
    (fixture) => {
      const packageJson = JSON.parse(fs.readFileSync(fixture.packageJson, 'utf8'));
      packageJson.devDependencies.wrangler = '^4.110.0';
      fs.writeFileSync(fixture.packageJson, `${JSON.stringify(packageJson, null, 2)}\n`);
    },
    (fixture) => {
      const config = JSON.parse(fs.readFileSync(fixture.config, 'utf8'));
      config.routes.push({ pattern: 'downloads.burnbar.ai/*', zone_name: 'burnbar.ai' });
      fs.writeFileSync(fixture.config, `${JSON.stringify(config, null, 2)}\n`);
    },
    (fixture) => {
      const config = JSON.parse(fs.readFileSync(fixture.uploadConfig, 'utf8'));
      config.routes.push({ pattern: 'downloads.burnbar.ai/linux/repository-admin/*', zone_name: 'burnbar.ai' });
      fs.writeFileSync(fixture.uploadConfig, `${JSON.stringify(config, null, 2)}\n`);
    },
    (fixture) => {
      const config = JSON.parse(fs.readFileSync(fixture.uploadConfig, 'utf8'));
      config.vars = { UNSAFE_DRIFT: true };
      fs.writeFileSync(fixture.uploadConfig, `${JSON.stringify(config, null, 2)}\n`);
    },
    (fixture) => {
      const config = JSON.parse(fs.readFileSync(fixture.uploadConfig, 'utf8'));
      config.name = 'openburnbar-linux-repository-router';
      fs.writeFileSync(fixture.uploadConfig, `${JSON.stringify(config, null, 2)}\n`);
    },
    (fixture) => {
      const config = JSON.parse(fs.readFileSync(fixture.controlConfig, 'utf8'));
      config.routes[0].pattern = 'downloads.burnbar.ai/*';
      fs.writeFileSync(fixture.controlConfig, `${JSON.stringify(config, null, 2)}\n`);
    }
  ]) {
    const fixture = createFixture();
    try {
      mutate(fixture);
      const result = runSetup(fixture, validEnvironment(fixture), ['--provision-only']);
      assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
      assert.equal(fs.readFileSync(fixture.log, 'utf8'), '');
    } finally {
      fixture.cleanup();
    }
  }
});

test('setup never contains an unpinned Wrangler fallback or r2.dev enablement', () => {
  const source = fs.readFileSync(sourceScript, 'utf8');
  assert.doesNotMatch(source, /wrangler@latest|npm exec|command -v wrangler/u);
  assert.doesNotMatch(source, /dev-url|r2\.dev/u);
  assert.match(source, /npm ci --prefix "\$worker_dir" --ignore-scripts --no-audit --no-fund/u);
  assert.match(source, /--secrets-file "\$upload_secret_file"/u);
  assert.match(source, /--secrets-file "\$activation_secret_file"/u);
  assert.doesNotMatch(source, /--config "\$worker_config" \\\n\s+--secrets-file/u);
  assert.match(source, /--strict/u);
});

function validEnvironment(fixture) {
  const env = { ...process.env };
  for (const name of requiredEnvironment) delete env[name];
  return {
    ...env,
    PATH: `${fixture.bin}:${process.env.PATH}`,
    FAKE_CLOUDFLARE_STATE: fixture.state,
    FAKE_SETUP_LOG: fixture.log,
    EXPECTED_ACTIVATION_TOKEN: 'activation-token-with-at-least-32-characters',
    EXPECTED_UPLOAD_TOKEN: 'upload-token-with-at-least-32-characters',
    CLOUDFLARE_API_TOKEN: 'cloudflare-api-token-for-test',
    CLOUDFLARE_ACCOUNT_ID: 'a'.repeat(32),
    OPENBURNBAR_R2_BUCKET: 'openburnbar-downloads',
    OPENBURNBAR_R2_CUSTOM_DOMAIN: 'downloads.burnbar.ai',
    OPENBURNBAR_R2_ZONE_ID: 'b'.repeat(32),
    OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: 'upload-token-with-at-least-32-characters',
    OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: 'activation-token-with-at-least-32-characters'
  };
}

function runSetup(fixture, env, args = []) {
  return spawnSync('bash', [fixture.script, ...args], {
    cwd: fixture.root,
    encoding: 'utf8',
    env
  });
}

function createFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-linux-r2-setup-'));
  const scripts = path.join(root, 'scripts');
  const worker = path.join(root, 'workers/linux-repository-router');
  const bin = path.join(root, 'bin');
  const state = path.join(root, 'state');
  const log = path.join(root, 'setup.log');
  for (const directory of [scripts, worker, bin, state, path.join(worker, 'node_modules/.bin')]) {
    fs.mkdirSync(directory, { recursive: true });
  }
  const script = path.join(scripts, 'setup-linux-downloads-r2.sh');
  fs.copyFileSync(sourceScript, script);
  fs.chmodSync(script, 0o755);
  fs.writeFileSync(log, '');

  const packageJson = path.join(worker, 'package.json');
  const lock = path.join(worker, 'package-lock.json');
  const config = path.join(worker, 'wrangler.jsonc');
  const uploadConfig = path.join(worker, 'wrangler-upload.jsonc');
  const controlConfig = path.join(worker, 'wrangler-control.jsonc');
  const feedConfig = path.join(worker, 'wrangler-feed.jsonc');
  fs.writeFileSync(packageJson, `${JSON.stringify({
    private: true,
    devDependencies: { wrangler: '4.110.0' }
  }, null, 2)}\n`);
  fs.writeFileSync(lock, `${JSON.stringify({
    lockfileVersion: 3,
    packages: {
      '': { devDependencies: { wrangler: '4.110.0' } },
      'node_modules/wrangler': { version: '4.110.0' }
    }
  }, null, 2)}\n`);
  const commonConfig = {
    $schema: './node_modules/wrangler/config-schema.json',
    main: 'src/index.mjs',
    compatibility_date: '2026-07-10',
    workers_dev: false,
    r2_buckets: [{ binding: 'REPOSITORY_BUCKET', bucket_name: 'openburnbar-downloads' }]
  };
  fs.writeFileSync(config, `${JSON.stringify({
    ...commonConfig,
    name: 'openburnbar-linux-repository-router',
    vars: { WORKER_ROLE: 'serving' },
    routes: [
      { pattern: 'downloads.burnbar.ai/linux/apt/*', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/linux/rpm/*', zone_name: 'burnbar.ai' }
    ]
  }, null, 2)}\n`);
  fs.writeFileSync(uploadConfig, `${JSON.stringify({
    ...commonConfig,
    name: 'openburnbar-linux-repository-uploader',
    vars: { WORKER_ROLE: 'upload' },
    routes: [
      { pattern: 'downloads.burnbar.ai/linux/repository-upload/*', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/linux/repository-preview/*', zone_name: 'burnbar.ai' }
    ]
  }, null, 2)}\n`);
  fs.writeFileSync(controlConfig, `${JSON.stringify({
    ...commonConfig,
    name: 'openburnbar-linux-repository-control',
    vars: { WORKER_ROLE: 'control' },
    routes: [
      { pattern: 'downloads.burnbar.ai/linux/repository-admin/*', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/linux/repository-activations/*', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/linux/update-feed-activation.json', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/linux/update-feed-activations/*', zone_name: 'burnbar.ai' }
    ]
  }, null, 2)}\n`);
  fs.writeFileSync(feedConfig, `${JSON.stringify({
    ...commonConfig,
    name: 'openburnbar-linux-update-feed',
    vars: { WORKER_ROLE: 'feed' },
    routes: [
      { pattern: 'downloads.burnbar.ai/latest-linux.json', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/latest-linux.json.ed25519.sig', zone_name: 'burnbar.ai' },
      { pattern: 'downloads.burnbar.ai/linux/update/*', zone_name: 'burnbar.ai' }
    ]
  }, null, 2)}\n`);

  fs.writeFileSync(path.join(bin, 'npm'), `#!${process.execPath}\n${fakeNpmSource()}\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'curl'), `#!${process.execPath}\n${fakeCurlSource()}\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(worker, 'node_modules/.bin/wrangler'), `#!${process.execPath}\n${fakeWranglerSource()}\n`, { mode: 0o755 });

  return {
    root,
    script,
    worker,
    bin,
    state,
    log,
    packageJson,
    lock,
    config,
    uploadConfig,
    controlConfig,
    feedConfig,
    cleanup: () => fs.rmSync(root, { recursive: true, force: true })
  };
}

function fakeCurlSource() {
  return String.raw`
const fs = require('node:fs');
const args = process.argv.slice(2);
const outputIndex = args.indexOf('--output');
const url = args.at(-1);
const hasAuthorization = args.some((arg) => /authorization|bearer/iu.test(arg));
const retries = args[args.indexOf('--retry') + 1];
fs.appendFileSync(process.env.FAKE_SETUP_LOG,
  'curl guard ' + new URL(url).pathname + (hasAuthorization ? ' auth' : ' no-auth') + ' retries=' + retries + '\n');
if (process.env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN
    || process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN) process.exit(20);
if (outputIndex < 0 || args[outputIndex + 1] === undefined) process.exit(21);
const body = process.env.FAKE_GUARD_MODE === 'raw-bucket-404'
  ? '<Error><Code>NoSuchKey</Code></Error>\n'
  : '{"error":"repository route is unavailable for this worker role"}\n';
fs.writeFileSync(args[outputIndex + 1], body);
process.stdout.write('404');
`;
}

function fakeNpmSource() {
  return String.raw`
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const workerIndex = args.indexOf('--prefix');
const normalized = args.map((arg, index) => index === workerIndex + 1 ? 'WORKER' : arg);
fs.appendFileSync(process.env.FAKE_SETUP_LOG, 'npm ' + normalized.join(' ') + '\n');
`;
}

function fakeWranglerSource() {
  return String.raw`
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const state = process.env.FAKE_CLOUDFLARE_STATE;
const log = (value) => fs.appendFileSync(process.env.FAKE_SETUP_LOG, value + '\n');
if (args[0] === '--version') {
  process.stdout.write('4.110.0\n');
  process.exit(0);
}
if (args[0] === 'r2' && args[1] === 'bucket' && args[2] === 'info') {
  log('wrangler r2 bucket info');
  if (!fs.existsSync(path.join(state, 'bucket'))) process.exit(1);
  process.stdout.write('{"name":"openburnbar-downloads"}\n');
  process.exit(0);
}
if (args[0] === 'r2' && args[1] === 'bucket' && args[2] === 'create') {
  log('wrangler r2 bucket create');
  fs.writeFileSync(path.join(state, 'bucket'), 'created\n');
  process.exit(0);
}
if (args[0] === 'r2' && args[1] === 'bucket' && args[2] === 'domain' && args[3] === 'get') {
  log('wrangler r2 bucket domain get');
  if (!fs.existsSync(path.join(state, 'domain'))) process.exit(1);
  process.stdout.write('downloads.burnbar.ai connected\n');
  process.exit(0);
}
if (args[0] === 'r2' && args[1] === 'bucket' && args[2] === 'domain' && args[3] === 'add') {
  log('wrangler r2 bucket domain add');
  fs.writeFileSync(path.join(state, 'domain'), 'downloads.burnbar.ai\n');
  process.exit(0);
}
if (args[0] === 'deploy') {
  const configPath = args[args.indexOf('--config') + 1];
  if (['wrangler.jsonc', 'wrangler-feed.jsonc'].includes(path.basename(configPath))) {
    if (args.includes('--secrets-file') || !args.includes('--strict')) process.exit(10);
    log('wrangler deploy ' + path.basename(configPath) + ' no-secrets');
    process.exit(0);
  }
  const secretPath = args[args.indexOf('--secrets-file') + 1];
  const secret = JSON.parse(fs.readFileSync(secretPath, 'utf8'));
  const mode = fs.statSync(secretPath).mode & 0o777;
  const upload = path.basename(configPath) === 'wrangler-upload.jsonc';
  const expectedName = upload
    ? 'OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN'
    : 'OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN';
  const expectedToken = upload ? process.env.EXPECTED_UPLOAD_TOKEN : process.env.EXPECTED_ACTIVATION_TOKEN;
  if (Object.keys(secret).length !== 1 || secret[expectedName] !== expectedToken) process.exit(11);
  if (mode !== 0o600) process.exit(12);
  if (!args.includes('--strict')) process.exit(13);
  log('wrangler deploy ' + path.basename(configPath) + ' secret-ok mode-600');
  process.exit(0);
}
process.stderr.write('unexpected fake Wrangler arguments: ' + args.join(' ') + '\n');
process.exit(99);
`;
}
