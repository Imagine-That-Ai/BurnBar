#!/usr/bin/env node
/**
 * Compile the TypeSpec canon and assert it matches the emitted TypeScript.
 *
 * Closes TECH_DEBT finding H27/finding-89 ("the .tsp canon never compiles, so
 * it silently rots while emit/generate.mjs is the de-facto source"). This gate:
 *
 *   1. Compiles typespec/main.tsp with @typespec/compiler and fails on any
 *      compile diagnostic — the canon must always be a valid TypeSpec program.
 *   2. For EVERY manifest domain, asserts the compiled model set is exactly the
 *      set of `export interface` declarations in the emitted TypeScript
 *      (functions/src/types/generated/<domain>.ts), and that every property
 *      matches by name, optionality, and normalized type — in BOTH directions.
 *
 * A domain may declare documentation-only models that are not (yet) wired into
 * the emit registry by listing them under `tspOnlyModels` in manifest.json.
 * The allowlist ratchets: an entry that disappears from the .tsp, or that
 * becomes emitted, fails the gate until it is removed — so the backlog can
 * only burn down, never silently grow.
 *
 * Type normalization maps TypeSpec scalars to their TypeScript emit (int32 ->
 * number, ...), sorts union members, and renders arrays as `Elem[]`
 * (parenthesized when the element is a union), so `("a" | "b")[]` compares
 * stably regardless of declaration order.
 *
 * Run via check-drift.sh (CI: fast-feedback schema-drift job) or directly:
 *   npm --prefix tools/schema-sync run check:canon
 */

import { join, dirname } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  compile,
  NodeHost,
  navigateProgram,
  getSourceLocation,
  isArrayModelType,
} from "@typespec/compiler";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");
const manifest = JSON.parse(readFileSync(join(__dirname, "manifest.json"), "utf8"));

const SCALAR_TO_TS = new Map([
  ["string", "string"],
  ["boolean", "boolean"],
  ["int8", "number"],
  ["int16", "number"],
  ["int32", "number"],
  ["int64", "number"],
  ["uint8", "number"],
  ["uint16", "number"],
  ["uint32", "number"],
  ["uint64", "number"],
  ["safeint", "number"],
  ["integer", "number"],
  ["float32", "number"],
  ["float64", "number"],
  ["numeric", "number"],
  ["decimal", "number"],
]);

/** Render a compiled TypeSpec type as its normalized TypeScript emit. */
function tspTypeToTs(program, type) {
  switch (type.kind) {
    case "Scalar": {
      const mapped = SCALAR_TO_TS.get(type.name);
      if (!mapped) throw new Error(`unmapped TypeSpec scalar "${type.name}"`);
      return mapped;
    }
    case "Model": {
      if (isArrayModelType(program, type)) {
        const element = tspTypeToTs(program, type.indexer.value);
        return element.includes(" | ") ? `(${element})[]` : `${element}[]`;
      }
      if (!type.name) throw new Error("anonymous model types are not allowed in the canon");
      return type.name;
    }
    case "Union": {
      const members = [...type.variants.values()].map((variant) => tspTypeToTs(program, variant.type));
      return [...new Set(members)].sort().join(" | ");
    }
    case "String":
      return JSON.stringify(type.value);
    case "Number":
      return String(type.value);
    case "Boolean":
      return String(type.value);
    default:
      throw new Error(`unsupported TypeSpec type kind "${type.kind}"`);
  }
}

/** Normalize a TypeScript type annotation string the same way. */
function normalizeTsType(raw) {
  const text = raw.trim();
  if (text.endsWith("[]")) {
    let inner = text.slice(0, -2).trim();
    if (inner.startsWith("(") && inner.endsWith(")")) inner = inner.slice(1, -1).trim();
    const element = normalizeTsType(inner);
    return element.includes(" | ") ? `(${element})[]` : `${element}[]`;
  }
  if (text.includes("|")) {
    const members = text.split("|").map((member) => normalizeTsType(member));
    return [...new Set(members)].sort().join(" | ");
  }
  return text;
}

/** Parse `export interface Name { ... }` blocks into Name -> Map(field -> {optional, type}). */
function parseGeneratedInterfaces(tsSource) {
  const interfaces = new Map();
  for (const block of tsSource.matchAll(/export interface (\w+)\s*\{([\s\S]*?)\n\}/gm)) {
    const fields = new Map();
    for (const line of block[2].matchAll(/^\s*(\w+)(\??):\s*(.+?);\s*$/gm)) {
      fields.set(line[1], { optional: line[2] === "?", type: normalizeTsType(line[3]) });
    }
    interfaces.set(block[1], fields);
  }
  return interfaces;
}

const program = await compile(NodeHost, join(__dirname, "typespec", "main.tsp"), { noEmit: true });
const errors = program.diagnostics.filter((diagnostic) => diagnostic.severity === "error");
for (const diagnostic of program.diagnostics) {
  const location = getSourceLocation(diagnostic.target);
  const where = location?.file ? `${location.file.path}` : "<unknown>";
  console.error(`tsp ${diagnostic.severity}: ${diagnostic.code} ${diagnostic.message} (${where})`);
}
if (errors.length > 0) {
  console.error(`TypeSpec canon failed to compile: ${errors.length} error(s).`);
  process.exit(1);
}

// Group compiled models by the domain .tsp file that declares them.
const modelsByFile = new Map();
navigateProgram(program, {
  model(model) {
    if (!model.name) return;
    const location = getSourceLocation(model);
    const path = location?.file?.path;
    if (!path || !path.includes("typespec/domains/")) return;
    if (!modelsByFile.has(path)) modelsByFile.set(path, new Map());
    modelsByFile.get(path).set(model.name, model);
  },
});

let failures = 0;
const fail = (message) => {
  failures += 1;
  console.error(message);
};

for (const domain of manifest.domains) {
  const tspPath = join(__dirname, domain.typespec);
  const models =
    [...modelsByFile.entries()].find(([path]) => path === tspPath || path.endsWith(`/${domain.typespec}`))?.[1] ??
    new Map();
  const generated = parseGeneratedInterfaces(readFileSync(join(repoRoot, domain.emit.typescript), "utf8"));

  const modelNames = new Set(models.keys());
  const interfaceNames = new Set(generated.keys());
  const tspOnly = new Set(domain.tspOnlyModels ?? []);
  for (const name of modelNames) {
    if (!interfaceNames.has(name) && !tspOnly.has(name)) {
      fail(
        `[${domain.id}] model "${name}" is in the .tsp canon but not emitted in ${domain.emit.typescript}. ` +
          `Wire it into emit/generate.mjs, or list it under this domain's tspOnlyModels in manifest.json.`
      );
    }
  }
  for (const name of interfaceNames) {
    if (!modelNames.has(name)) {
      fail(`[${domain.id}] interface "${name}" is emitted in ${domain.emit.typescript} but missing from the .tsp canon`);
    }
  }
  for (const name of tspOnly) {
    if (!modelNames.has(name)) {
      fail(`[${domain.id}] tspOnlyModels lists "${name}" but the .tsp canon no longer declares it — remove the stale entry`);
    } else if (interfaceNames.has(name)) {
      fail(`[${domain.id}] tspOnlyModels lists "${name}" but it is emitted now — remove it from the allowlist so the ratchet keeps binding`);
    }
  }

  for (const [name, model] of models) {
    const fields = generated.get(name);
    if (!fields) continue; // already reported above
    const modelProps = new Map();
    for (const [propName, prop] of model.properties) {
      let rendered;
      try {
        rendered = tspTypeToTs(program, prop.type);
      } catch (error) {
        fail(`[${domain.id}] ${name}.${propName}: ${String(error.message ?? error)}`);
        continue;
      }
      modelProps.set(propName, { optional: prop.optional, type: rendered });
    }
    for (const [propName, expected] of modelProps) {
      const actual = fields.get(propName);
      if (!actual) {
        fail(`[${domain.id}] ${name}.${propName} is in the .tsp canon but not in the emitted interface`);
        continue;
      }
      if (actual.optional !== expected.optional) {
        fail(
          `[${domain.id}] ${name}.${propName} optionality mismatch: .tsp says ${expected.optional ? "optional" : "required"}, emit says ${actual.optional ? "optional" : "required"}`
        );
      }
      if (actual.type !== expected.type) {
        fail(`[${domain.id}] ${name}.${propName} type mismatch: .tsp "${expected.type}" vs emit "${actual.type}"`);
      }
    }
    for (const propName of fields.keys()) {
      if (!modelProps.has(propName)) {
        fail(`[${domain.id}] ${name}.${propName} is emitted but missing from the .tsp canon`);
      }
    }
  }

  if (failures === 0) {
    console.log(`tsp-canon check passed: ${domain.id} (${modelNames.size} model(s))`);
  }
}

if (failures > 0) {
  console.error(`tsp-canon check FAILED with ${failures} mismatch(es). The .tsp canon and emit/generate.mjs must stay in lockstep.`);
  process.exit(1);
}
console.log(`tsp-canon check: compiled canon matches emitted TypeScript across ${manifest.domains.length} domain(s).`);
