#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

const fixtureMirrors = [
  {
    name: 'city-key console',
    canonical: 'tests/fixtures/city-key-goldens.json',
    mirror: 'apps/console/lib/community/city-key-goldens.json',
  },
  {
    name: 'city-key linux desktop',
    canonical: 'tests/fixtures/city-key-goldens.json',
    mirror: 'apps/linux-desktop/src/community/city-key-goldens.json',
  },
  {
    name: 'city-key android JVM resources',
    canonical: 'tests/fixtures/city-key-goldens.json',
    mirror: 'android/app/src/test/resources/city-key-goldens.json',
  },
  {
    name: 'city-key windows tests',
    canonical: 'tests/fixtures/city-key-goldens.json',
    mirror: 'windows/tests/community/Fixtures/city-key-goldens.json',
  },
  {
    name: 'classifier Apple tests',
    canonical: 'tests/fixtures/classifier-goldens.json',
    mirror: 'AgentLensTests/Fixtures/classifier-goldens.json',
  },
];

function normalizedJson(path) {
  const raw = readFileSync(resolve(repoRoot, path), 'utf8');
  return JSON.stringify(JSON.parse(raw));
}

const failures = [];
for (const { name, canonical, mirror } of fixtureMirrors) {
  if (normalizedJson(canonical) !== normalizedJson(mirror)) {
    failures.push(`${name}: ${mirror} drifted from ${canonical}`);
  }
}

if (failures.length > 0) {
  console.error('Community golden fixture drift detected:');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Community golden fixture drift check passed (${fixtureMirrors.length} mirrors).`);
