#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { extractInterfaceFields, extractKotlinMirrorFields, extractSwiftMirrorFields } from '../../tools/schema-sync/check-hand-mirror.mjs';
import { SCHEMA_BOUNDARY_PATH } from './check-mobile-schema-boundary.mjs';
import { readJson, runCheckCli, walkMobileSources } from './lib/check-support.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const GENERATED_TS_DIR = 'functions/src/types/generated';
export const GENERATED_SWIFT_DIR = 'OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels';
export const GENERATED_KT_DIR = 'android/app/src/main/java/com/openburnbar/data/models/generated';

function listFiles(relativeDir, suffix) {
  const resolved = resolveConfinedPath(repoRoot, relativeDir);
  if (resolved.error || !resolved.exists) throw new Error(`missing ${relativeDir}`);
  return fs.readdirSync(resolved.path)
    .filter((name) => name.endsWith(suffix) && name !== 'index.ts')
    .map((name) => path.join(relativeDir, name));
}

function exportedTsInterfaces(source) {
  return [...source.matchAll(/export interface (\w+)/g)].map((match) => match[1]);
}

function exportedSwiftStructs(source) {
  return [...source.matchAll(/public struct (Firestore\w+)/g)].map((match) => match[1]);
}

function exportedKotlinClasses(source) {
  return [...source.matchAll(/(?:data )?class (Firestore\w+)/g)].map((match) => match[1]);
}

export function collectGeneratedContracts(root = repoRoot) {
  const tsTypes = new Map();
  for (const rel of listFiles(GENERATED_TS_DIR, '.ts')) {
    const source = fs.readFileSync(path.join(root, rel), 'utf8');
    for (const name of exportedTsInterfaces(source)) {
      tsTypes.set(name, { path: rel, fields: extractInterfaceFields(source, name) });
    }
  }
  const swiftTypes = new Map();
  for (const rel of listFiles(GENERATED_SWIFT_DIR, '.swift')) {
    const source = fs.readFileSync(path.join(root, rel), 'utf8');
    for (const name of exportedSwiftStructs(source)) {
      swiftTypes.set(name, { path: rel, fields: extractSwiftMirrorFields(source) });
    }
  }
  const kotlinTypes = new Map();
  for (const rel of listFiles(GENERATED_KT_DIR, '.kt')) {
    const source = fs.readFileSync(path.join(root, rel), 'utf8');
    for (const name of exportedKotlinClasses(source)) {
      kotlinTypes.set(name, { path: rel, fields: extractKotlinMirrorFields(source) });
    }
  }
  return { tsTypes, swiftTypes, kotlinTypes };
}

/** Hand-written mobile sources only — the generated mirrors are the contract. */
function walkConsumerFiles(root) {
  return walkMobileSources(
    [
      path.join(root, 'OpenBurnBarMobile'),
      path.join(root, 'OpenBurnBarCore/Sources/OpenBurnBarKernel'),
      path.join(root, 'android/app/src/main/java/com/openburnbar')
    ],
    ['generated']
  );
}

export const LEGACY_DECODER_ALLOWLIST = [
  'OpenBurnBarMobile/Services/FirestoreRepository.swift',
  'android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt',
  'android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRollupMerger.kt'
];

export function mappedCollectionsFromBoundary(root = repoRoot, boundary) {
  const document = boundary ?? readJson(root, SCHEMA_BOUNDARY_PATH).value;
  return (document?.documents ?? [])
    .filter((row) => row?.kind === 'typespec' && row.collection && row.generatedType)
    .map((row) => ({ collection: row.collection, generatedType: row.generatedType, callable: false }))
    .concat(
      (document?.callables ?? [])
        .filter((row) => row?.kind === 'typespec' && row.name && row.generatedType)
        .map((row) => ({ collection: row.name, generatedType: row.generatedType, callable: true }))
    );
}

export function validateMobileGeneratedConsumers(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const contracts = options.contracts ?? collectGeneratedContracts(root);
  const consumerFiles = options.files ?? walkConsumerFiles(root);
  const allowlist = new Set(options.legacyAllowlist ?? LEGACY_DECODER_ALLOWLIST);
  const mapped = options.mappedCollections ?? mappedCollectionsFromBoundary(root, options.boundary);

  for (const file of consumerFiles) {
    const text = fs.readFileSync(file, 'utf8');
    const rel = path.relative(root, file).split(path.sep).join('/');
    const usesGenerated = text.includes('OpenBurnBarFirestoreModels')
      || text.includes('com.openburnbar.data.models.generated');
    if (usesGenerated) {
      for (const match of text.matchAll(/\b(Firestore[A-Z][A-Za-z0-9]+)\b/g)) {
        const typeName = match[1];
        if (!/(?:Doc|Bucket|ConnectContext|Token)$/.test(typeName)) continue;
        const known = contracts.swiftTypes.has(typeName) || contracts.kotlinTypes.has(typeName);
        if (!known) {
          failures.push(`${rel} references unknown generated type ${typeName}`);
        }
      }
    }
    for (const mapping of mapped) {
      const mentionsCollection = new RegExp(`collection\\(["']${mapping.collection}["']\\)`).test(text);
      if (!mentionsCollection) continue;
      const handType = mapping.generatedType;
      const generatedType = `Firestore${handType}`;
      const decodesHand = new RegExp(
        `(?:decode\\(\\s*${handType}\\b|${handType}\\.self|fromJson\\(\\s*${handType}|${handType}\\s*::class)`
      ).test(text);
      const decodesGenerated = text.includes(generatedType);
      if (decodesHand && !decodesGenerated && !allowlist.has(rel)) {
        failures.push(
          `${rel} decodes mapped collection ${mapping.collection} via hand type ${handType} instead of ${generatedType}`
        );
      }
    }
  }

  return { passed: failures.length === 0, failures };
}

runCheckCli(import.meta.url, validateMobileGeneratedConsumers, () => 'mobile generated-consumer check ok');
