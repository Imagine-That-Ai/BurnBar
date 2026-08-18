#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { extractInterfaceFields } from '../../tools/schema-sync/check-hand-mirror.mjs';
import { collectGeneratedContracts } from './check-mobile-generated-consumers.mjs';
import { isObject, readJson, runCheckCli } from './lib/check-support.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const FIXTURE_MANIFEST_PATH = 'docs/mobile-parity/fixtures/schema/manifest.json';

const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

export function decodeGeneratedDocument(fields, payload, options = {}) {
  const errors = [];
  if (!isObject(payload)) {
    return { ok: false, errors: ['payload must be an object'] };
  }
  if (options.allowUnknownFields === false) {
    for (const key of Object.keys(payload)) {
      if (!fields.has(key)) errors.push(`unknown field ${key}`);
    }
  }
  for (const [name, spec] of fields) {
    const present = Object.hasOwn(payload, name);
    const value = payload[name];
    if (!present) {
      if (!spec.optional) errors.push(`missing required field ${name}`);
      continue;
    }
    if (value === null) {
      if (!spec.optional && options.nullMeansAbsent !== true) {
        errors.push(`null is not allowed on required field ${name}`);
      }
      continue;
    }
    if (spec.kind === 'number' && typeof value !== 'number') {
      errors.push(`field ${name} must be a number`);
    }
    if (spec.kind === 'string' && typeof value !== 'string') {
      errors.push(`field ${name} must be a string`);
    }
    if (spec.kind === 'boolean' && typeof value !== 'boolean') {
      errors.push(`field ${name} must be a boolean`);
    }
    if (spec.enumValues && !spec.enumValues.includes(value)) {
      errors.push(`field ${name} has unknown enum value ${value}`);
    }
    if (spec.timestamp && typeof value === 'string' && !ISO_TIMESTAMP.test(value)) {
      errors.push(`field ${name} is not an ISO-8601 timestamp`);
    }
  }
  return { ok: errors.length === 0, errors };
}

function inferKind(rawType) {
  if (/\bnumber\b/.test(rawType)) return 'number';
  if (/\bboolean\b/.test(rawType)) return 'boolean';
  if (/\bstring\b/.test(rawType)) return 'string';
  return 'unknown';
}

export function fieldsFromGeneratedTs(source, interfaceName) {
  const extracted = extractInterfaceFields(source, interfaceName);
  const fields = new Map();
  if (!extracted) return fields;
  for (const [name, optional] of extracted) {
    const line = source.split('\n').find((candidate) => new RegExp(`\\b${name}\\??\\s*:`).test(candidate)) ?? '';
    const typePart = line.split(':').slice(1).join(':').replace(/;.*$/, '').trim();
    const enumValues = [...typePart.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
    fields.set(name, {
      optional: optional === true,
      kind: inferKind(typePart),
      enumValues: enumValues.length ? enumValues : undefined,
      timestamp: name === 'recordedAt' || name === 'fetchedAt' || name === 'createdAt' || name === 'updatedAt' || name === 'expiresAt'
    });
  }
  return fields;
}

export function validateCrossLanguageFixtures(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const manifestRel = options.manifestPath ?? FIXTURE_MANIFEST_PATH;
  const manifestDocument = readJson(root, manifestRel, 'missing fixture manifest:');
  if (manifestDocument.error) return { passed: false, failures: [manifestDocument.error] };
  const manifest = manifestDocument.value;
  const contracts = options.contracts ?? collectGeneratedContracts(root);

  for (const suite of manifest.suites ?? []) {
    const ts = contracts.tsTypes.get(suite.generatedType);
    if (!ts) {
      failures.push(`${suite.id} references unknown generated type ${suite.generatedType}`);
      continue;
    }
    const source = fs.readFileSync(path.join(root, ts.path), 'utf8');
    const fields = fieldsFromGeneratedTs(source, suite.generatedType);
    const fixtureDocument = readJson(root, suite.fixture, `${suite.id} fixture missing:`);
    if (fixtureDocument.error) {
      failures.push(fixtureDocument.error);
      continue;
    }
    const fixture = fixtureDocument.value;

    for (const passing of fixture.pass ?? []) {
      const result = decodeGeneratedDocument(fields, passing.document, { allowUnknownFields: true });
      if (!result.ok) {
        failures.push(`${suite.id}/${passing.id} should pass: ${result.errors.join('; ')}`);
      }
    }
    for (const failing of fixture.fail ?? []) {
      const result = decodeGeneratedDocument(fields, failing.document, { allowUnknownFields: failing.allowUnknownFields === true });
      if (result.ok) {
        failures.push(`${suite.id}/${failing.id} should fail closed`);
      }
    }

    const generatedName = `Firestore${suite.generatedType}`;
    const swiftFields = fieldNameSet(contracts.swiftTypes.get(generatedName)?.fields);
    const kotlinFields = fieldNameSet(contracts.kotlinTypes.get(generatedName)?.fields);
    const tsNames = new Set(fields.keys());
    if (swiftFields.size && !coversFieldSet(swiftFields, tsNames)) {
      failures.push(`${suite.id} Swift field set is missing generated TypeScript fields`);
    }
    if (kotlinFields.size && !coversFieldSet(kotlinFields, tsNames)) {
      failures.push(`${suite.id} Kotlin field set is missing generated TypeScript fields`);
    }

    const happy = (fixture.pass ?? []).find((item) => item.id === 'happy');
    if (happy) {
      const mutated = { ...happy.document };
      const required = [...fields.entries()].find(([, spec]) => !spec.optional);
      if (required) {
        const [name] = required;
        mutated[`${name}__renamed`] = mutated[name];
        delete mutated[name];
        const result = decodeGeneratedDocument(fields, mutated, { allowUnknownFields: true });
        if (result.ok) {
          failures.push(`${suite.id} field-rename drift of ${name} must fail the parity check`);
        }
      }
    }
  }

  return { passed: failures.length === 0, failures };
}

function fieldNameSet(fields) {
  if (!fields) return new Set();
  if (fields instanceof Set) return fields;
  if (fields instanceof Map) return new Set(fields.keys());
  if (Array.isArray(fields)) return new Set(fields);
  return new Set(Object.keys(fields));
}

function coversFieldSet(generated, expected) {
  for (const name of expected) {
    if (!generated.has(name)) return false;
  }
  return true;
}

runCheckCli(import.meta.url, validateCrossLanguageFixtures, () => 'cross-language schema fixtures ok');
