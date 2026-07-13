#!/usr/bin/env node
/**
 * Compare two platform evidence artifacts without exposing credential values.
 *
 * This is an evidence oracle, not a parity claim. It proves only that the two
 * supplied JSON artifacts normalize to the same (or intentionally different)
 * contract at the time the command is run.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REDACTED = '[REDACTED]';
const IGNORED = '[IGNORED]';

export class DifferentialUsageError extends Error {}

function usage() {
  return [
    'Usage: node scripts/linux-port/run-platform-differential.mjs --macos <json> --linux <json> [--out <json>] [--ignore <dotted.path>]',
    '',
    'Exit codes: 0 exact match, 1 unapproved differences, 2 invalid input or usage.'
  ].join('\n');
}

export function parseArgs(argv) {
  const result = { macos: null, linux: null, out: null, ignore: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = () => {
      const next = argv[index + 1];
      if (!next || next.startsWith('--')) {
        throw new DifferentialUsageError(`${arg} requires a value.`);
      }
      index += 1;
      return next;
    };
    if (arg === '--macos') result.macos = value();
    else if (arg === '--linux') result.linux = value();
    else if (arg === '--out') result.out = value();
    else if (arg === '--ignore') result.ignore.push(value());
    else if (arg.startsWith('--ignore=')) result.ignore.push(arg.slice('--ignore='.length));
    else if (arg === '--help' || arg === '-h') throw new DifferentialUsageError(usage());
    else throw new DifferentialUsageError(`Unknown argument: ${arg}\n\n${usage()}`);
  }
  if (!result.macos || !result.linux) {
    throw new DifferentialUsageError(`Both --macos and --linux are required.\n\n${usage()}`);
  }
  result.ignore = [...new Set(result.ignore.map((entry) => entry.trim()).filter(Boolean))];
  return result;
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isSecretKey(key) {
  const snakeCase = key.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase();
  return /(?:^|_)(?:access|refresh|id|auth|bearer)?_?token$/.test(snakeCase)
    || /(?:^|_)(?:password|secret|api_key|private_key|access_key|credential|authorization)$/.test(snakeCase);
}

function pathForKey(parent, key) {
  return parent === '$' ? `$.${key}` : `${parent}.${key}`;
}

function pathForIndex(parent, index) {
  return `${parent}[${index}]`;
}

function shouldIgnore(currentPath, ignored) {
  return ignored.has(currentPath);
}

/** Normalize keys recursively so object order and credential values are stable. */
export function normalizeArtifact(value, options = {}) {
  const ignored = new Set(options.ignore ?? []);
  function normalize(current, currentPath) {
    if (shouldIgnore(currentPath, ignored)) return IGNORED;
    if (Array.isArray(current)) {
      return current.map((entry, index) => normalize(entry, pathForIndex(currentPath, index)));
    }
    if (isObject(current)) {
      return Object.fromEntries(
        Object.keys(current).sort().map((key) => {
          const childPath = pathForKey(currentPath, key);
          return [key, isSecretKey(key) ? REDACTED : normalize(current[key], childPath)];
        })
      );
    }
    return current;
  }
  return normalize(value, '$');
}

function stableJson(value) {
  return JSON.stringify(value);
}

function sha256(value) {
  return crypto.createHash('sha256').update(stableJson(value)).digest('hex');
}

const MISSING = Symbol('missing');

function diffValues(expected, actual, currentPath, differences) {
  if (expected === MISSING || actual === MISSING) {
    differences.push({
      path: currentPath,
      expected: expected === MISSING ? undefined : expected,
      actual: actual === MISSING ? undefined : actual,
      kind: expected === MISSING ? 'added' : 'removed'
    });
    return;
  }
  if (Object.is(expected, actual)) return;
  if (Array.isArray(expected) && Array.isArray(actual)) {
    const length = Math.max(expected.length, actual.length);
    for (let index = 0; index < length; index += 1) {
      diffValues(
        index < expected.length ? expected[index] : MISSING,
        index < actual.length ? actual[index] : MISSING,
        pathForIndex(currentPath, index),
        differences
      );
    }
    return;
  }
  if (isObject(expected) && isObject(actual)) {
    const keys = [...new Set([...Object.keys(expected), ...Object.keys(actual)])].sort();
    for (const key of keys) {
      diffValues(
        Object.hasOwn(expected, key) ? expected[key] : MISSING,
        Object.hasOwn(actual, key) ? actual[key] : MISSING,
        pathForKey(currentPath, key),
        differences
      );
    }
    return;
  }
  differences.push({ path: currentPath, expected, actual, kind: 'changed' });
}

export function compareArtifacts(macos, linux, options = {}) {
  const normalizedMacos = normalizeArtifact(macos, options);
  const normalizedLinux = normalizeArtifact(linux, options);
  const differences = [];
  diffValues(normalizedMacos, normalizedLinux, '$', differences);
  return {
    schemaVersion: 1,
    status: differences.length === 0 ? 'exact_match' : 'differences',
    ignoredPaths: [...new Set(options.ignore ?? [])].sort(),
    // Keep reports reviewable without copying whole transcripts or project
    // payloads into the evidence bundle. Differences are path-scoped below.
    macos: { sha256: sha256(normalizedMacos) },
    linux: { sha256: sha256(normalizedLinux) },
    differences
  };
}

function readJson(filePath, label) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    throw new Error(`${label} artifact could not be read: ${error.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} artifact is not valid JSON: ${error.message}`);
  }
}

export function buildReport(args) {
  try {
    return compareArtifacts(
      readJson(args.macos, 'macOS'),
      readJson(args.linux, 'Linux'),
      { ignore: args.ignore }
    );
  } catch (error) {
    return {
      schemaVersion: 1,
      status: 'invalid',
      errors: [error instanceof Error ? error.message : String(error)],
      differences: []
    };
  }
}

export function run(argv, io = {}) {
  const stdout = io.stdout ?? process.stdout;
  const stderr = io.stderr ?? process.stderr;
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    stdout.write(`${JSON.stringify({ schemaVersion: 1, status: 'invalid', errors: [message], differences: [] }, null, 2)}\n`);
    if (error instanceof DifferentialUsageError) stderr.write(`${message}\n`);
    return 2;
  }
  const report = buildReport(args);
  const output = `${JSON.stringify(report, null, 2)}\n`;
  if (args.out) {
    const destination = path.resolve(args.out);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, output, 'utf8');
  }
  stdout.write(output);
  return report.status === 'exact_match' ? 0 : report.status === 'differences' ? 1 : 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = run(process.argv.slice(2));
}
