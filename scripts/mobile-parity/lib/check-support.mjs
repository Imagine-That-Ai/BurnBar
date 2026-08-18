import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PLACEHOLDER_EVIDENCE } from './mobile-parity-constants.mjs';
import { resolveConfinedPath } from './path-confine.mjs';

export function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function looksLikePlaceholder(text) {
  return PLACEHOLDER_EVIDENCE.some((pattern) => pattern.test(text));
}

/**
 * Parse a repository-relative JSON document, returning `{ error }` when it is
 * absent instead of throwing so callers can accumulate failures.
 */
export function readJson(root, relative, label = 'missing') {
  const resolved = resolveConfinedPath(root, relative);
  if (resolved.error || !resolved.exists) return { error: `${label} ${relative}` };
  return { value: JSON.parse(fs.readFileSync(resolved.path, 'utf8')), path: resolved.path };
}

/** True when a repository-relative file exists and contains `id` verbatim. */
export function fileMentions(root, relative, id) {
  const resolved = resolveConfinedPath(root, relative);
  if (resolved.error || !resolved.exists) return false;
  return fs.readFileSync(resolved.path, 'utf8').includes(id);
}

/** Collect every file under an absolute path; a file path yields itself. */
export function walkFiles(absPath, acc = []) {
  if (!fs.existsSync(absPath)) return acc;
  const stat = fs.statSync(absPath);
  if (stat.isFile()) {
    acc.push(absPath);
    return acc;
  }
  if (!stat.isDirectory()) return acc;
  for (const entry of fs.readdirSync(absPath)) {
    if (entry === '.git') continue;
    walkFiles(path.join(absPath, entry), acc);
  }
  return acc;
}

/**
 * Collect the Swift/Kotlin sources under each absolute root, skipping dot
 * entries and any directory named in `skipDirs`.
 */
export function walkMobileSources(roots, skipDirs = []) {
  const skip = new Set(skipDirs);
  const files = [];
  const visit = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('.') || skip.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.isFile() && /\.(swift|kt)$/.test(entry.name)) files.push(full);
    }
  };
  for (const dir of roots) visit(dir);
  return files;
}

export function isMainModule(moduleUrl) {
  return Boolean(process.argv[1]) && path.resolve(process.argv[1]) === fileURLToPath(moduleUrl);
}

/**
 * Standard check entrypoint: print every failure to stderr and exit 1, else
 * print the summary line. No-op when the module was imported, not executed.
 */
export function runCheckCli(moduleUrl, validate, summarize) {
  if (!isMainModule(moduleUrl)) return;
  const result = validate();
  if (!result.passed) {
    for (const message of result.failures) console.error(message);
    process.exit(1);
  }
  console.log(summarize(result));
}
