import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { createSignedEngineManifest, signingPayload } from './sign-linux-text-expansion-engine.mjs';

const ENGINE = path.resolve('packaging/linux/openburnbar-text-expansion-engine.py');

test('engine performs a bounded handshake and daemon-owned lookup result', () => {
  const input = [
    { operation: 'handshake', protocol: 'openburnbar.text-expansion', protocolVersion: 1, engineID: 'org.openburnbar.TextExpansion', noGlobalCapture: true, readsClipboard: false, readsSurroundingText: false, secureFieldPolicy: 'deny-unless-inspectable-and-explicitly-nonsecure' },
    { operation: 'expand', protocol: 'openburnbar.text-expansion', protocolVersion: 1, requestID: 'request-1', trigger: '&&hello', replacement: 'Hello' }
  ].map((row) => JSON.stringify(row)).join('\n') + '\n';
  const result = spawnSync(ENGINE, ['--engine-id', 'org.openburnbar.TextExpansion'], { input, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const rows = result.stdout.trim().split('\n').map(JSON.parse);
  assert.equal(rows[0].ready, true);
  assert.deepEqual(rows[1], { operation: 'expand_result', protocol: 'openburnbar.text-expansion', protocolVersion: 1, requestID: 'request-1', status: 'expanded', replacement: 'Hello' });
  assert.doesNotMatch(result.stdout + result.stderr, /bearer|authToken|socket\.token|api[_-]?key/iu);
});

test('engine rejects oversized, malformed, and mismatched protocol input', () => {
  for (const input of ['x'.repeat(65 * 1024) + '\n', '{}\n', '{bad}\n']) {
    const result = spawnSync(ENGINE, [], { input, encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.equal(result.stdout, '');
  }
});

test('signed manifest is bound to exact executable bytes and backend', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-ime-sign-'));
  try {
    const executable = path.join(root, 'engine');
    fs.copyFileSync(ENGINE, executable);
    const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
    const manifest = createSignedEngineManifest({ backend: 'ibus', executable, privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }) });
    const signature = Buffer.from(manifest.signature.signatureBase64, 'base64');
    assert.equal(crypto.verify(null, signingPayload(manifest), publicKey, signature), true);
    assert.equal(manifest.executableSha256, crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex'));
    fs.appendFileSync(executable, '#tamper\n');
    assert.notEqual(manifest.executableSha256, crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex'));
    assert.equal(crypto.verify(null, signingPayload({ ...manifest, backend: 'fcitx5' }), publicKey, signature), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('IBus component invokes only the root-installed engine path', () => {
  const xml = fs.readFileSync('packaging/linux/ibus-openburnbar.xml', 'utf8');
  assert.match(xml, /<exec>\/usr\/libexec\/openburnbar\/text-expansion-engine --ibus<\/exec>/u);
  assert.doesNotMatch(xml, /\/home\/|\/tmp\//u);
});

test('secure-purpose denial and delimiter replacement plan are exact', () => {
  const result = spawnSync(ENGINE, ['--self-test'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {
    unknownDenied: true,
    passwordDenied: true,
    pinDenied: true,
    freeFormAllowed: true,
    plan: { backspaces: 7, text: 'Hello ' }
  });
});

test('IBus helper forwards only non-secret daemon discovery environment', () => {
  const source = fs.readFileSync(ENGINE, 'utf8');
  assert.match(source, /CLI_ENVIRONMENT_KEYS/u);
  assert.match(source, /OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE/u);
  assert.doesNotMatch(source, /OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN[",]/u);
  assert.doesNotMatch(source, /OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY/u);
});

test('IBus helper fails closed when the daemon CLI is unavailable or times out', () => {
  const source = fs.readFileSync(ENGINE, 'utf8');
  assert.match(
    source,
    /try:\n\s+result = subprocess\.run\([\s\S]*?\n\s+except \(OSError, subprocess\.TimeoutExpired\):\n\s+# An unavailable or wedged daemon must not take down the IBus worker\./u
  );
  assert.match(source, /return None\n\s+if result\.returncode != 0/u);
});

test('IBus worker observes SIGTERM and exits its GLib loop', () => {
  const source = fs.readFileSync(ENGINE, 'utf8');
  assert.match(source, /GLib\.timeout_add\(100, stop_when_signalled\)/u);
  assert.match(source, /if STOP:\s+loop\.quit\(\)\s+return False/su);
});

test('deb rpm and Arch package the usable IBus runtime while AppImage fails closed', () => {
  const config = JSON.parse(fs.readFileSync('apps/linux-desktop/src-tauri/tauri.conf.json', 'utf8'));
  const { deb, rpm, appimage } = config.bundle.linux;
  assert.ok(deb.depends.includes('ibus'));
  assert.ok(deb.depends.includes('python3-gi'));
  assert.ok(rpm.depends.includes('ibus'));
  assert.ok(rpm.depends.includes('python3-gobject'));
  for (const section of [deb, rpm]) {
    assert.equal(section.files['/usr/libexec/openburnbar/text-expansion-engine'], '../../../packaging/linux/openburnbar-text-expansion-engine.py');
    assert.ok(section.files['/usr/share/ibus/component/openburnbar.xml']);
    assert.ok(section.files['/usr/share/openburnbar/text-expansion/text-expansion-engine.json']);
  }
  assert.ok(appimage.files['/usr/share/openburnbar/text-expansion/text-expansion-engine.json']);
  const launcher = fs.readFileSync('packaging/linux/openburnbar-daemon-launch.sh', 'utf8');
  assert.match(launcher, /A manifest signed for \/usr\/libexec cannot authenticate a transient AppImage/u);
  assert.match(launcher, /export OPENBURNBAR_LINUX_TEXT_EXPANSION_EXTERNAL=1/u);
  const pkgbuild = fs.readFileSync('packaging/linux/aur/PKGBUILD.in', 'utf8');
  for (const marker of ['"ibus"', '"python-gobject"', '/usr/libexec/openburnbar/text-expansion-engine', '/usr/share/ibus/component/openburnbar.xml']) {
    assert.ok(pkgbuild.includes(marker), marker);
  }
});
