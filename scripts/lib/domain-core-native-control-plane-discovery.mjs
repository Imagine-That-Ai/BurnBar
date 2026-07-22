import { lstatSync, readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";

const REPO_REFERENCE =
  /(?:^|[\s"'`(=])(?:\.\/)?((?:scripts|tools|config|AgentLens|OpenBurnBarCore|android|windows)\/[A-Za-z0-9_+./-]+\.(?:json|mjs|cjs|kts|swift|js|py|sh|kt|cs))(?=[\s"'`),\]])/gmu;
const RELATIVE_MODULE =
  /(?:from\s+|import\s*\(|import\s+|require\s*\(|export\s+[^\n]*?from\s+)["'](\.\.?\/[A-Za-z0-9_+./-]+)["']/gmu;

function regularFile(path) {
  try {
    const stat = lstatSync(path);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function repoRelative(root, path) {
  const value = relative(root, resolve(path));
  if (value.startsWith("..") || value.startsWith("/")) return null;
  return value;
}

export function discoverLocalReferences(root, sourcePath, source) {
  const references = new Set();
  for (const match of source.matchAll(REPO_REFERENCE)) {
    const path = match[1];
    if (regularFile(resolve(root, path))) references.add(path);
  }
  for (const match of source.matchAll(RELATIVE_MODULE)) {
    const imported = repoRelative(
      root,
      resolve(dirname(resolve(root, sourcePath)), match[1]),
    );
    if (imported && regularFile(resolve(root, imported))) {
      references.add(imported);
    }
  }
  return [...references].sort();
}

export function discoverControlPlaneClosure(root, entrypoints) {
  const closure = new Set();
  const pending = [...entrypoints];
  while (pending.length > 0) {
    const path = pending.pop();
    if (closure.has(path)) continue;
    const absolute = resolve(root, path);
    if (!regularFile(absolute)) {
      throw new Error(`control-plane reference is not a regular file: ${path}`);
    }
    closure.add(path);
    if (!/\.(?:cjs|js|mjs|py|sh|ya?ml)$/u.test(path)) continue;
    const source = readFileSync(absolute, "utf8");
    for (const dependency of discoverLocalReferences(root, path, source)) {
      if (!closure.has(dependency)) pending.push(dependency);
    }
  }
  return [...closure].sort();
}
