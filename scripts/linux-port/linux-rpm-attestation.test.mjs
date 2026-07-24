import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { replaceRpmAttestationFromPayload } from './lib/linux-rpm-attestation.mjs';

function writeAttestation(root, manifest, signature) {
  const directory = path.join(root, 'usr/share/openburnbar/attestation');
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'installed-manifest.json'), manifest, { mode: 0o600 });
  fs.writeFileSync(path.join(directory, 'installed-manifest.json.sig'), signature, { mode: 0o600 });
}

function writePayloadAttestation(directory, manifest, signature) {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'installed-manifest.json'), manifest, { mode: 0o600 });
  fs.writeFileSync(path.join(directory, 'installed-manifest.json.sig'), signature, { mode: 0o600 });
}

test('RPM staging replaces DEB attestation bytes with the signed RPM bytes', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-rpm-attestation-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const extractedRoot = path.join(root, 'extracted');
  const payloadAttestation = path.join(root, 'payload-attestation');
  writeAttestation(extractedRoot, Buffer.from('{"packageFormat":"deb"}\n'), Buffer.alloc(64, 1));
  writePayloadAttestation(payloadAttestation, Buffer.from('{"packageFormat":"rpm"}\n'), Buffer.alloc(64, 2));

  replaceRpmAttestationFromPayload({ extractedRoot, payloadAttestation });

  const destination = path.join(extractedRoot, 'usr/share/openburnbar/attestation');
  assert.deepEqual(fs.readFileSync(path.join(destination, 'installed-manifest.json')), Buffer.from('{"packageFormat":"rpm"}\n'));
  assert.deepEqual(fs.readFileSync(path.join(destination, 'installed-manifest.json.sig')), Buffer.alloc(64, 2));
  assert.equal(fs.statSync(path.join(destination, 'installed-manifest.json')).mode & 0o777, 0o644);
  assert.equal(fs.statSync(path.join(destination, 'installed-manifest.json.sig')).mode & 0o777, 0o644);
});

test('RPM staging rejects symlinked attestation sources and destinations', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-rpm-attestation-links-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const extractedRoot = path.join(root, 'extracted');
  const payloadAttestation = path.join(root, 'payload-attestation');
  writeAttestation(extractedRoot, Buffer.from('deb\n'), Buffer.alloc(64, 1));
  writePayloadAttestation(payloadAttestation, Buffer.from('rpm\n'), Buffer.alloc(64, 2));
  const source = path.join(payloadAttestation, 'installed-manifest.json');
  fs.renameSync(source, `${source}.real`);
  fs.symlinkSync('installed-manifest.json.real', source);
  assert.throws(
    () => replaceRpmAttestationFromPayload({ extractedRoot, payloadAttestation }),
    /source is not a regular file/u
  );

  fs.unlinkSync(source);
  fs.renameSync(`${source}.real`, source);
  const destination = path.join(extractedRoot, 'usr/share/openburnbar/attestation/installed-manifest.json');
  fs.unlinkSync(destination);
  fs.symlinkSync('installed-manifest.json.sig', destination);
  assert.throws(
    () => replaceRpmAttestationFromPayload({ extractedRoot, payloadAttestation }),
    /destination is not a regular file/u
  );
});
