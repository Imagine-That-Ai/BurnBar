#!/usr/bin/env node
import fs from 'node:fs';
import { readJson, runCheckCli } from './lib/check-support.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';
import { repoRoot } from './lib/repo-root.mjs';
import { scanMobileSchemaConsumers } from './lib/scan-mobile-schema-consumers.mjs';

export const SCHEMA_BOUNDARY_PATH = 'docs/mobile-parity/mobile-schema-boundary.json';
export const SCHEMA_BOUNDARY_ID = 'openburnbar-mobile-schema-boundary-v1';

function loadJson(root, relativePath, failures) {
  const document = readJson(root, relativePath, 'cannot read');
  if (document.error) {
    failures.push(document.error);
    return null;
  }
  return document.value;
}

export function validateMobileSchemaBoundary(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const boundary = options.boundary ?? loadJson(root, SCHEMA_BOUNDARY_PATH, failures);
  const manifest = options.manifest ?? loadJson(root, 'tools/schema-sync/manifest.json', failures);
  if (!boundary || !manifest) return { passed: false, failures };

  if (boundary.schemaVersion !== 1) failures.push('schema boundary schemaVersion must be 1');
  if (boundary.id !== SCHEMA_BOUNDARY_ID) failures.push(`schema boundary id must be ${SCHEMA_BOUNDARY_ID}`);
  if (!Array.isArray(boundary.documents) || boundary.documents.length === 0) {
    failures.push('schema boundary has no documents');
  }
  if (!Array.isArray(boundary.callables) || boundary.callables.length === 0) {
    failures.push('schema boundary has no callables');
  }

  const domainIds = new Set((manifest.domains ?? []).map((domain) => domain.id));
  const documentsByCollection = new Map();
  for (const doc of boundary.documents ?? []) {
    if (!doc?.collection || !doc?.kind || !doc?.owner) {
      failures.push(`document ${doc?.id ?? '<missing>'} needs collection, kind, and owner`);
      continue;
    }
    if (documentsByCollection.has(doc.collection)) {
      failures.push(`duplicate document collection: ${doc.collection}`);
    }
    documentsByCollection.set(doc.collection, doc);
    if (doc.kind === 'typespec') {
      if (!domainIds.has(doc.domainId)) failures.push(`document ${doc.collection} names unknown TypeSpec domain ${doc.domainId}`);
      if (doc.generatedType) {
        const emit = (manifest.domains ?? []).find((domain) => domain.id === doc.domainId)?.emit?.typescript;
        if (!emit) {
          failures.push(`document ${doc.collection} TypeSpec domain ${doc.domainId} has no TypeScript emit`);
        } else {
          const generated = resolveConfinedPath(root, emit);
          if (generated.error || !generated.exists) {
            failures.push(`generated TypeScript missing for ${doc.collection}: ${emit}`);
          } else {
            const source = fs.readFileSync(generated.path, 'utf8');
            if (!source.includes(`export interface ${doc.generatedType}`)) {
              failures.push(`generated TypeScript for ${doc.domainId} does not export ${doc.generatedType}`);
            }
          }
        }
      }
    } else if (doc.kind === 'legacy-boundary') {
      if (!doc.legacyId || !doc.removalCondition) {
        failures.push(`legacy document ${doc.collection} must name legacyId and removalCondition`);
      }
    } else {
      failures.push(`document ${doc.collection} has unknown kind ${doc.kind}`);
    }
  }

  const callablesByName = new Map();
  for (const callable of boundary.callables ?? []) {
    if (!callable?.name || !callable?.kind || !callable?.owner) {
      failures.push(`callable ${callable?.id ?? '<missing>'} needs name, kind, and owner`);
      continue;
    }
    if (callablesByName.has(callable.name)) failures.push(`duplicate callable: ${callable.name}`);
    callablesByName.set(callable.name, callable);
    if (callable.kind === 'typespec') {
      if (!domainIds.has(callable.domainId)) {
        failures.push(`callable ${callable.name} names unknown TypeSpec domain ${callable.domainId}`);
      }
    } else if (callable.kind === 'legacy-boundary') {
      if (!callable.legacyId || !callable.removalCondition) {
        failures.push(`legacy callable ${callable.name} must name legacyId and removalCondition`);
      }
    } else {
      failures.push(`callable ${callable.name} has unknown kind ${callable.kind}`);
    }
  }

  const scan = options.scan ?? scanMobileSchemaConsumers(root);
  for (const collection of scan.collections) {
    if (!documentsByCollection.has(collection)) {
      failures.push(`mobile consumer collection is unmapped: ${collection}`);
    }
  }
  for (const name of scan.callables) {
    if (!callablesByName.has(name)) {
      failures.push(`mobile consumer callable is unmapped: ${name}`);
    }
  }

  return { passed: failures.length === 0, failures, scan };
}

runCheckCli(
  import.meta.url,
  validateMobileSchemaBoundary,
  (result) =>
    `mobile schema boundary ok: ${result.scan.collections.length} collections, ${result.scan.callables.length} callables`
);
