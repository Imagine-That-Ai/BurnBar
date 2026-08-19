import fs from 'node:fs';
import path from 'node:path';
import { walkMobileSources } from './check-support.mjs';

const SKIP_DIRS = ['.git', 'build', 'DerivedData', 'node_modules'];

function lastCollectionSegment(raw) {
  return raw
    .replaceAll('\\(uid)', '{uid}')
    .replaceAll('${uid}', '{uid}')
    .replaceAll('\\(documentID)', '{docId}')
    .split('/')
    .filter(Boolean)
    .at(-1);
}

export function scanMobileSchemaConsumers(repoRoot) {
  const roots = [
    path.join(repoRoot, 'OpenBurnBarMobile'),
    path.join(repoRoot, 'android/app/src/main/java/com/openburnbar')
  ];
  const collections = new Set();
  const callables = new Set();

  for (const file of walkMobileSources(roots, SKIP_DIRS)) {
    const text = fs.readFileSync(file, 'utf8');
    for (const match of text.matchAll(/collection\("([^"]+)"\)/g)) {
      const segment = lastCollectionSegment(match[1]);
      if (segment && segment !== 'users') collections.add(segment);
    }
    for (const match of text.matchAll(/httpsCallable\("([^"]+)"\)/g)) {
      callables.add(match[1]);
    }
    for (const match of text.matchAll(/getHttpsCallable\("([^"]+)"\)/g)) {
      callables.add(match[1]);
    }
  }

  return {
    collections: [...collections].sort(),
    callables: [...callables].sort()
  };
}
