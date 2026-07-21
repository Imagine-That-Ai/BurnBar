#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const value = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1]?.trim() : null;
};

export function signingPayload(manifest) {
  return Buffer.from([
    `schema_version=${manifest.schemaVersion}`,
    `backend=${manifest.backend}`,
    `engine_id=${manifest.engineID}`,
    `executable_path=${manifest.executablePath}`,
    `executable_sha256=${manifest.executableSha256}`,
    `supports_wayland=${manifest.supportsWayland}`,
    `supports_x11=${manifest.supportsX11}`,
    `no_global_capture=${manifest.noGlobalCapture}`,
    `reads_clipboard=${manifest.readsClipboard}`,
    `reads_surrounding_text=${manifest.readsSurroundingText}`,
    `secure_field_policy=${manifest.secureFieldPolicy}`,
    ''
  ].join('\n'));
}

export function createSignedEngineManifest({
  backend,
  executable,
  installedExecutable = '/usr/libexec/openburnbar/text-expansion-engine',
  privateKeyPem
}) {
  if (!['ibus', 'fcitx5'].includes(backend)) throw new Error('backend must be ibus or fcitx5');
  const stat = fs.lstatSync(executable);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('engine executable must be a regular file');
  const privateKey = crypto.createPrivateKey(privateKeyPem);
  if (privateKey.asymmetricKeyType !== 'ed25519') throw new Error('engine manifest requires an Ed25519 key');
  const publicKey = crypto.createPublicKey(privateKey);
  const publicDer = publicKey.export({ type: 'spki', format: 'der' });
  const rawPublicKey = publicDer.subarray(publicDer.length - 32);
  const manifest = {
    schemaVersion: 2,
    backend,
    engineID: 'org.openburnbar.TextExpansion',
    executablePath: installedExecutable,
    executableSha256: crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex'),
    supportsWayland: true,
    supportsX11: true,
    noGlobalCapture: true,
    readsClipboard: false,
    readsSurroundingText: false,
    secureFieldPolicy: 'deny-unless-inspectable-and-explicitly-nonsecure'
  };
  const signature = crypto.sign(null, signingPayload(manifest), privateKey);
  return {
    ...manifest,
    signature: {
      algorithm: 'ed25519',
      publicKeyBase64: rawPublicKey.toString('base64'),
      signatureBase64: signature.toString('base64')
    }
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    const executable = value('--executable');
    const output = value('--output');
    const backend = value('--backend');
    const privateKeyPem = process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM;
    if (!executable || !output || !backend || !privateKeyPem) {
      throw new Error('--executable, --output, --backend, and OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM are required');
    }
    const manifest = createSignedEngineManifest({ backend, executable, privateKeyPem });
    fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
    fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644, flag: 'wx' });
  } catch (error) {
    process.stderr.write(`sign-linux-text-expansion-engine: ${error.message}\n`);
    process.exitCode = 1;
  }
}
