#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  candidateCloseRefusal,
  collectCandidateFingerprint
} from './lib/candidate-fingerprint.mjs';
import { isMainModule } from './lib/check-support.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const DEFAULT_RECEIPT_PATH = 'docs/mobile-parity/evidence/candidate-fingerprint.json';

export const PACKAGE_IDS = {
  ios: 'com.openburnbar.app',
  iosWidget: 'com.openburnbar.app.widget',
  android: 'com.openburnbar'
};

export function buildCandidateReceipt(repoRootPath, options = {}) {
  const fingerprint = options.fingerprint ?? collectCandidateFingerprint(repoRootPath);
  const refusal = candidateCloseRefusal(fingerprint);
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-candidate-fingerprint-v1',
    recordedAt: options.recordedAt ?? new Date().toISOString(),
    commitSha: fingerprint.commitSha,
    dirty: fingerprint.dirty === true,
    dirtyEntries: fingerprint.dirtyEntries ?? [],
    version: {
      ios: options.iosVersion ?? null,
      android: options.androidVersion ?? null,
      note: 'unbound until a signed artifact is recorded'
    },
    build: {
      ios: options.iosBuild ?? null,
      android: options.androidBuild ?? null,
      note: 'unbound until a signed artifact is recorded'
    },
    packageIds: { ...PACKAGE_IDS, ...(options.packageIds ?? {}) },
    nativeArtifacts: fingerprint.nativeArtifacts ?? options.nativeArtifacts ?? [],
    closable: refusal === null,
    closeRefusal: refusal
  };
}

export function writeCandidateReceipt(repoRootPath, relativePath = DEFAULT_RECEIPT_PATH, options = {}) {
  const receipt = buildCandidateReceipt(repoRootPath, options);
  if (options.requireClosable === true && receipt.closable !== true) {
    return { receipt, wrote: false, error: receipt.closeRefusal ?? 'candidate is not closable' };
  }
  const resolved = resolveConfinedPath(repoRootPath, relativePath);
  if (resolved.error) {
    return { receipt, wrote: false, error: resolved.error };
  }
  fs.mkdirSync(path.dirname(resolved.path), { recursive: true });
  fs.writeFileSync(resolved.path, `${JSON.stringify(receipt, null, 2)}\n`);
  return { receipt, wrote: true, path: relativePath };
}

function parseArgs(argv) {
  const args = { out: DEFAULT_RECEIPT_PATH, requireClosable: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') args.out = argv[++index];
    else if (arg === '--require-closable') args.requireClosable = true;
    else if (arg === '--stdout') args.stdout = true;
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = writeCandidateReceipt(repoRoot, args.out, {
    requireClosable: args.requireClosable
  });
  if (args.stdout) {
    console.log(JSON.stringify(result.receipt, null, 2));
  }
  if (!result.wrote) {
    console.error(result.error);
    process.exit(1);
  }
  if (!args.stdout) {
    console.log(JSON.stringify({
      path: result.path,
      closable: result.receipt.closable,
      dirty: result.receipt.dirty,
      commitSha: result.receipt.commitSha
    }, null, 2));
  }
  if (result.receipt.closable !== true) {
    process.exitCode = 2;
  }
}

if (isMainModule(import.meta.url)) main();
