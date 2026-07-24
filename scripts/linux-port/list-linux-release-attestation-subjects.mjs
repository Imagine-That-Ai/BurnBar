#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  deriveReleaseAttestationSubjects,
  validateRecord
} from './lib/product-proof-closure.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release'));
const closure = JSON.parse(fs.readFileSync(path.join(outDir, 'package-closure.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'packaging/linux/release-manifest.json'), 'utf8'));
const subjects = deriveReleaseAttestationSubjects(closure, manifest.requiredArtifacts);

for (const subject of subjects) {
  const absolute = validateRecord(repoRoot, subject.record, `${subject.role} attestation subject`).absolute;
  const relative = path.relative(repoRoot, absolute);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('release attestation subject escapes the repository');
  }
  process.stdout.write(`${absolute}\0`);
}
