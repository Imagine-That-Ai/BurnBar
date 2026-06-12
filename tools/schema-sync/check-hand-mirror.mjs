#!/usr/bin/env node
/**
 * Verify hand-maintained schema mirrors still carry every field the generated
 * Firestore canon defines. Complements check-drift.sh (which guards generated
 * output only).
 *
 * Scope of this gate (closes TECH_DEBT finding H27/finding-89/finding-84):
 *   - Loops EVERY manifest domain, not just provider-account.
 *   - Compares parsed field name + optionality (`?`) instead of a raw
 *     substring includes() that a comment or unrelated identifier could satisfy.
 *   - Registers functions/src/types/legacy.ts as a `tsHandMirror` so the doc
 *     types it re-declares a second time are field-checked against the canon.
 *
 * A mirror "carries" a generated interface when, for every field the generated
 * interface declares, the mirror declares a field with the same name and (for
 * TypeScript mirrors) the same optionality. Native (Swift/Kotlin) mirrors do not
 * encode TS `?:` optionality, so for them only field-name presence is checked.
 *
 * Pre-existing divergence between the de-facto legacy registry and the thinner
 * generated canon is real drift (the TypeSpec strangler migration backlog). It
 * is grandfathered per mirror via `knownDrift` so the gate PASSES on current
 * code while failing closed on any NEW drift, and the gate fails if a listed
 * `knownDrift` entry is no longer real (stale grandfather) so the list ratchets
 * down as the migration burns it off. Do NOT "fix" the drift by editing
 * legacy.ts here — burn it down domain-at-a-time via the strangler plan.
 */

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");
const manifest = JSON.parse(
  readFileSync(join(__dirname, "manifest.json"), "utf8")
);

/**
 * Parse an exported TS interface into an ordered map of fieldName -> isOptional.
 * Returns null when the interface is not declared as `export interface NAME {`
 * (e.g. derived `export type X = Omit<...>`, or simply absent).
 */
function extractInterfaceFields(tsSource, interfaceName) {
  const pattern = new RegExp(
    `export interface ${interfaceName}\\s*\\{([\\s\\S]*?)\\n\\}`,
    "m"
  );
  const match = tsSource.match(pattern);
  if (!match) return null;
  const body = match[1];
  const fields = new Map();
  for (const m of body.matchAll(/^\s*(\w+)(\??)\s*:/gm)) {
    fields.set(m[1], m[2] === "?");
  }
  return fields;
}

function readGenerated(domain) {
  return readFileSync(join(repoRoot, domain.emit.typescript), "utf8");
}

/** Every generated `export interface` name in a domain's TypeScript output. */
function generatedInterfaceNames(generated) {
  return [...generated.matchAll(/^export interface (\w+)/gm)].map((m) => m[1]);
}

function normalizeMirror(entry) {
  if (typeof entry === "string") return { path: entry };
  return entry;
}

/**
 * Diff one mirror against the target generated interfaces.
 * @returns {string[]} drift tokens — `Interface.field` for a missing field,
 *   `Interface.field#opt` for an optionality mismatch (TS mirrors only).
 */
function diffMirror({ generated, mirrorSource, interfaces, compareOptionality }) {
  const drift = [];
  for (const interfaceName of interfaces) {
    const genFields = extractInterfaceFields(generated, interfaceName);
    if (!genFields) {
      throw new Error(
        `manifest names interface "${interfaceName}" but the generated canon does not declare it`
      );
    }
    const mirrorFields = compareOptionality
      ? extractInterfaceFields(mirrorSource, interfaceName)
      : null;
    if (compareOptionality && !mirrorFields) {
      throw new Error(
        `TS mirror is registered for "${interfaceName}" but does not re-declare it as an interface`
      );
    }
    for (const [field, optional] of genFields) {
      if (compareOptionality) {
        if (!mirrorFields.has(field)) {
          drift.push(`${interfaceName}.${field}`);
        } else if (mirrorFields.get(field) !== optional) {
          drift.push(`${interfaceName}.${field}#opt`);
        }
      } else if (!mirrorSource.includes(field)) {
        drift.push(`${interfaceName}.${field}`);
      }
    }
  }
  return drift;
}

/**
 * Resolve which generated interfaces a mirror must carry. Explicit `interfaces`
 * wins; otherwise, for a TS mirror default to every generated interface the
 * mirror file itself re-declares (auto-detected dual definitions), and for a
 * native mirror default to every generated interface in the domain.
 */
function resolveInterfaces(entry, generated, mirrorSource, compareOptionality) {
  if (Array.isArray(entry.interfaces)) return entry.interfaces;
  const all = generatedInterfaceNames(generated);
  if (!compareOptionality) return all;
  return all.filter((name) => extractInterfaceFields(mirrorSource, name));
}

function checkMirror({ domain, generated, entry, compareOptionality }) {
  const mirror = normalizeMirror(entry);
  const mirrorSource = readFileSync(join(repoRoot, mirror.path), "utf8");
  const interfaces = resolveInterfaces(
    mirror,
    generated,
    mirrorSource,
    compareOptionality
  );
  if (interfaces.length === 0) return; // nothing dual-defined to check

  const drift = diffMirror({
    generated,
    mirrorSource,
    interfaces,
    compareOptionality,
  });
  const known = new Set(mirror.knownDrift ?? []);
  const liveDrift = new Set(drift);

  const unlisted = drift.filter((token) => !known.has(token));
  if (unlisted.length > 0) {
    throw new Error(
      `[${domain.id}] ${mirror.path} drifted from the generated canon — fields present in generated output but missing/optionality-mismatched in the mirror: ${unlisted.join(", ")}. ` +
        `Mirror the field(s), or grandfather them under this mirror's knownDrift in tools/schema-sync/manifest.json with a follow-up to converge.`
    );
  }
  const stale = [...known].filter((token) => !liveDrift.has(token));
  if (stale.length > 0) {
    throw new Error(
      `[${domain.id}] ${mirror.path} knownDrift lists entries that are no longer real drift: ${stale.join(", ")}. ` +
        `Remove them from manifest.json so the ratchet keeps binding.`
    );
  }
}

let failures = 0;
let checked = 0;
for (const domain of manifest.domains) {
  let generated;
  try {
    generated = readGenerated(domain);
  } catch (error) {
    failures += 1;
    console.error(`[${domain.id}] ${String(error.message ?? error)}`);
    continue;
  }

  const mirrors = [
    ...(domain.swiftHandMirror ?? []).map((entry) => ({
      entry,
      compareOptionality: false,
    })),
    ...(domain.kotlinHandMirror ?? []).map((entry) => ({
      entry,
      compareOptionality: false,
    })),
    ...(domain.tsHandMirror ?? []).map((entry) => ({
      entry,
      compareOptionality: true,
    })),
  ];

  for (const { entry, compareOptionality } of mirrors) {
    checked += 1;
    try {
      checkMirror({ domain, generated, entry, compareOptionality });
    } catch (error) {
      failures += 1;
      console.error(String(error.message ?? error));
    }
  }

  if (mirrors.length > 0 && failures === 0) {
    console.log(`hand-mirror check passed: ${domain.id} (${mirrors.length} mirror(s))`);
  }
}

console.log(`hand-mirror check: ${checked} mirror(s) across all manifest domains`);

if (failures > 0) {
  process.exit(1);
}
