#!/usr/bin/env node

import { existsSync, lstatSync, readdirSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const OBSERVER_TARGETS = Object.freeze([
  "healthCheck",
  "healthLive",
  "healthReady",
]);
const STATIC_IMPORT = /(?:\bfrom\s*|\bimport\s*)(["'])(\.{1,2}\/[^"']+)\1/gmu;
const NAMED_REEXPORT =
  /\bexport\s*\{([^}]*)\}\s*from\s*(["'])(\.{1,2}\/[^"']+)\2\s*;/gmu;

function sourceFiles(root) {
  const files = [];
  function visit(directory) {
    for (const name of readdirSync(directory).sort()) {
      const path = resolve(directory, name);
      const stat = lstatSync(path);
      if (stat.isSymbolicLink())
        throw new Error(`source graph contains symlink: ${path}`);
      if (stat.isDirectory()) {
        if (name !== "__tests__") visit(path);
      } else if (
        stat.isFile() &&
        path.endsWith(".ts") &&
        !path.endsWith(".test.ts")
      ) {
        files.push(path);
      }
    }
  }
  visit(root);
  return files;
}

function resolveModule(importer, specifier) {
  const raw = resolve(dirname(importer), specifier);
  const candidates = [
    raw.replace(/\.js$/u, ".ts"),
    raw.replace(/\.mjs$/u, ".ts"),
    `${raw}.ts`,
    resolve(raw, "index.ts"),
  ];
  const match = candidates.find((path) => existsSync(path));
  if (!match)
    throw new Error(`${importer} references missing local module ${specifier}`);
  const stat = lstatSync(match);
  if (!stat.isFile() || stat.isSymbolicLink())
    throw new Error(`source graph module must be a regular file: ${match}`);
  return match;
}

function withoutComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//gmu, "")
    .replace(/(^|[^:])\/\/.*$/gmu, "$1");
}

function parseReexports(path, source) {
  const values = new Map();
  for (const match of source.matchAll(NAMED_REEXPORT)) {
    const target = resolveModule(path, match[3]);
    const body = match[1].replace(/\/\*[\s\S]*?\*\//gmu, "");
    for (const item of body.split(",")) {
      const value = item.trim();
      if (!value) continue;
      const parts = value.split(/\s+as\s+/u).map((part) => part.trim());
      if (
        parts.length > 2 ||
        parts.some((part) => !/^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(part))
      )
        throw new Error(`unsupported named re-export in ${path}: ${value}`);
      const imported = parts[0];
      const exported = parts[1] ?? imported;
      if (values.has(exported))
        throw new Error(`duplicate export ${exported} in ${path}`);
      values.set(exported, { imported, target });
    }
  }
  return values;
}

function reaches(graph, start, target, seen = new Set()) {
  if (start === target) return true;
  if (seen.has(start)) return false;
  seen.add(start);
  return [...(graph.get(start) ?? [])].some((next) =>
    reaches(graph, next, target, seen),
  );
}

function exportOrigin(modules, modulePath, name, seen = new Set()) {
  const key = `${modulePath}\0${name}`;
  if (seen.has(key)) throw new Error(`cyclic named re-export for ${name}`);
  seen.add(key);
  const module = modules.get(modulePath);
  const forwarded = module?.reexports.get(name);
  if (forwarded)
    return exportOrigin(modules, forwarded.target, forwarded.imported, seen);
  const declaration = new RegExp(
    `\\bexport\\s+(?:declare\\s+)?(?:async\\s+)?(?:const|function|class)\\s+${name}\\b`,
    "u",
  );
  if (!module || !declaration.test(module.source))
    throw new Error(
      `cannot resolve exported Function target ${name} from ${modulePath}`,
    );
  return modulePath;
}

export function deriveDomainCoreFunctionsTargets(
  repoRoot = ROOT,
  sourceRoot = resolve(repoRoot, "functions/src"),
) {
  const paths = sourceFiles(sourceRoot);
  const modules = new Map();
  const graph = new Map();
  for (const path of paths) {
    const source = readRegularFileSync(path, {
      encoding: "utf8",
      label: "Functions source module",
    });
    const syntax = withoutComments(source);
    const imports = new Set();
    for (const match of syntax.matchAll(STATIC_IMPORT))
      imports.add(resolveModule(path, match[2]));
    modules.set(path, {
      source: syntax,
      reexports: parseReexports(path, syntax),
    });
    graph.set(path, imports);
  }
  const indexPath = resolve(sourceRoot, "index.ts");
  const pricingPath = resolve(sourceRoot, "domainCorePricing.ts");
  const index = modules.get(indexPath);
  if (!index || !modules.has(pricingPath))
    throw new Error(
      "Functions source graph lacks index.ts or domainCorePricing.ts",
    );
  const targets = new Set(OBSERVER_TARGETS);
  for (const name of index.reexports.keys()) {
    const origin = exportOrigin(modules, indexPath, name);
    if (reaches(graph, origin, pricingPath)) targets.add(name);
  }
  for (const observer of OBSERVER_TARGETS)
    exportOrigin(modules, indexPath, observer);
  return [...targets].sort();
}

export function verifyDomainCoreFunctionsTargetInventory({
  repoRoot = ROOT,
  inventory,
}) {
  if (
    inventory?.schemaVersion !== 1 ||
    !Array.isArray(inventory.targets) ||
    inventory.targets.some((target) => typeof target !== "string")
  ) {
    throw new Error(
      "Functions target inventory must be schemaVersion 1 with string targets",
    );
  }
  const expected = deriveDomainCoreFunctionsTargets(repoRoot);
  const actual = [...inventory.targets].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Functions target inventory does not match the pricing execution graph: expected ${expected.join(", ")}; received ${actual.join(", ")}`,
    );
  }
  return { schemaVersion: 1, targets: expected };
}

function run(argv) {
  if (argv.length !== 2 || argv[0] !== "--inventory")
    throw new Error(
      "usage: verify-domain-core-functions-target-inventory.mjs --inventory PATH",
    );
  const inventoryPath = resolve(argv[1]);
  const result = verifyDomainCoreFunctionsTargetInventory({
    inventory: JSON.parse(
      readRegularFileSync(inventoryPath, {
        encoding: "utf8",
        label: "Functions target inventory",
      }),
    ),
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
