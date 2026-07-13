#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const publicKeyPath = path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem');

export function signProductProofClosure({
  closureFile,
  signatureFile,
  privateKeyPem,
  publicKeyPem = fs.readFileSync(publicKeyPath)
}) {
  if (!privateKeyPem) throw new Error('OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM is required');
  const closure = path.resolve(closureFile);
  const signature = path.resolve(signatureFile);
  const bytes = fs.readFileSync(closure);
  const document = JSON.parse(bytes.toString('utf8'));
  if (document.schemaVersion !== 2 || document.status !== 'passed'
      || document.stage !== 'candidate' || document.git?.dirty !== false
      || !/^[a-f0-9]{40,64}$/u.test(document.targetHead ?? '')
      || document.targetHead !== document.sourceCommit || document.git.commit !== document.targetHead) {
    throw new Error('product proof closure is not a clean, passed, commit-bound candidate');
  }
  const privateKey = crypto.createPrivateKey(privateKeyPem);
  const publicKey = crypto.createPublicKey(publicKeyPem);
  if (privateKey.asymmetricKeyType !== 'ed25519' || publicKey.asymmetricKeyType !== 'ed25519') {
    throw new Error('product proof closure signer requires Ed25519 keys');
  }
  const derived = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  const pinned = publicKey.export({ type: 'spki', format: 'der' });
  if (!derived.equals(pinned)) throw new Error('product proof closure signer does not match the pinned release public key');
  const signatureBytes = crypto.sign(null, bytes, privateKey);
  if (signatureBytes.length !== 64 || !crypto.verify(null, bytes, publicKey, signatureBytes)) {
    throw new Error('product proof closure signature failed self-verification');
  }
  fs.mkdirSync(path.dirname(signature), { recursive: true });
  fs.writeFileSync(signature, signatureBytes, { mode: 0o644 });
  return { closure, signature, size: signatureBytes.length };
}

function argument(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1]?.trim() : '';
  if (!value || value.startsWith('--')) throw new Error(`${name} is required`);
  return value;
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  try {
    const result = signProductProofClosure({
      closureFile: argument('--closure'),
      signatureFile: argument('--signature'),
      privateKeyPem: process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM
    });
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    console.error(`sign-product-proof-closure: ${error.message}`);
    process.exit(1);
  }
}
