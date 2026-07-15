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
 * TypeScript and C# mirrors) the same optionality. Swift/Kotlin mirrors do not
 * encode TS `?:` optionality, so for them only field-name presence is checked.
 *
 * C# mirrors are scoped per record: each generated interface is matched to the
 * C# record that mirrors it (`Firestore` + interface name, with a superset
 * fallback for union variants), and fields are checked against that specific
 * record. This prevents cross-record masking where a field removed from one
 * record is silently satisfied by the same field on a sibling record.
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

function loadManifest() {
  return JSON.parse(readFileSync(join(__dirname, "manifest.json"), "utf8"));
}

function countChar(source, char) {
  let count = 0;
  for (const candidate of source) {
    if (candidate === char) count += 1;
  }
  return count;
}

function stripComments(source) {
  let output = "";
  let state = "code";
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1] ?? "";

    if (state === "lineComment") {
      if (char === "\n") {
        output += "\n";
        state = "code";
      } else {
        output += " ";
      }
      continue;
    }

    if (state === "blockComment") {
      if (char === "*" && next === "/") {
        output += "  ";
        index += 1;
        state = "code";
      } else {
        output += char === "\n" ? "\n" : " ";
      }
      continue;
    }

    if (state === "doubleString") {
      output += char;
      if (char === "\\" && next) {
        output += next;
        index += 1;
      } else if (char === "\"") {
        state = "code";
      }
      continue;
    }

    if (state === "singleString") {
      output += char;
      if (char === "\\" && next) {
        output += next;
        index += 1;
      } else if (char === "'") {
        state = "code";
      }
      continue;
    }

    if (state === "templateString") {
      output += char;
      if (char === "\\" && next) {
        output += next;
        index += 1;
      } else if (char === "`") {
        state = "code";
      }
      continue;
    }

    if (char === "/" && next === "/") {
      output += "  ";
      index += 1;
      state = "lineComment";
    } else if (char === "/" && next === "*") {
      output += "  ";
      index += 1;
      state = "blockComment";
    } else if (char === "\"") {
      output += char;
      state = "doubleString";
    } else if (char === "'") {
      output += char;
      state = "singleString";
    } else if (char === "`") {
      output += char;
      state = "templateString";
    } else {
      output += char;
    }
  }
  return output;
}

function stripCommentsAndStrings(source) {
  let output = "";
  let state = "code";
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1] ?? "";

    if (state === "lineComment") {
      if (char === "\n") {
        output += "\n";
        state = "code";
      } else {
        output += " ";
      }
      continue;
    }

    if (state === "blockComment") {
      if (char === "*" && next === "/") {
        output += "  ";
        index += 1;
        state = "code";
      } else {
        output += char === "\n" ? "\n" : " ";
      }
      continue;
    }

    if (typeof state === "object") {
      if (char === "\\" && next) {
        output += "  ";
        index += 1;
      } else if (char === state.quote) {
        output += " ";
        state = "code";
      } else {
        output += char === "\n" ? "\n" : " ";
      }
      continue;
    }

    if (char === "/" && next === "/") {
      output += "  ";
      index += 1;
      state = "lineComment";
    } else if (char === "/" && next === "*") {
      output += "  ";
      index += 1;
      state = "blockComment";
    } else if (char === "\"" || char === "'" || char === "`") {
      output += " ";
      state = { quote: char };
    } else {
      output += char;
    }
  }
  return output;
}

/**
 * Parse an exported TS interface into an ordered map of fieldName -> isOptional.
 * Returns null when the interface is not declared as `export interface NAME {`
 * (e.g. derived `export type X = Omit<...>`, or simply absent).
 */
function extractInterfaceFields(tsSource, interfaceName) {
  const searchable = stripComments(tsSource);
  const pattern = new RegExp(
    `export interface ${interfaceName}\\s*\\{([\\s\\S]*?)\\n\\}`,
    "m"
  );
  const match = searchable.match(pattern);
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

function extractSwiftMirrorFields(swiftSource) {
  const fields = new Set();
  const source = stripCommentsAndStrings(swiftSource);
  let braceDepth = 0;

  for (const line of source.split("\n")) {
    if (braceDepth === 1) {
      const match = line.match(
        /^\s*(?:(?:open|public|package|internal|fileprivate|private)\s+)?(?:private\(set\)\s+)?(?:let|var)\s+([A-Za-z_]\w*)\b/
      );
      if (match) fields.add(match[1]);
    }
    braceDepth += countChar(line, "{") - countChar(line, "}");
    if (braceDepth < 0) braceDepth = 0;
  }

  return fields;
}

function extractKotlinMirrorFields(kotlinSource) {
  const fields = new Set();
  const source = stripComments(kotlinSource);
  let braceDepth = 0;
  let constructorParenDepth = 0;
  let pendingPropertyName = null;

  for (const line of source.split("\n")) {
    const propertyNameMatch = line.match(
      /@(?:get:|set:)?PropertyName\s*\(\s*"([^"]+)"\s*\)/
    );
    if (propertyNameMatch) {
      pendingPropertyName = propertyNameMatch[1];
    }

    if (/^\s*(?:data\s+)?class\s+\w+\s*\(/.test(line)) {
      constructorParenDepth += countChar(line, "(") - countChar(line, ")");
    }

    const inConstructor = constructorParenDepth > 0;
    const inClassBody = braceDepth === 1;
    if (inConstructor || inClassBody) {
      const propertyMatch = line.match(/^\s*(?:@[^\n]+\s*)*(?:val|var)\s+([A-Za-z_]\w*)\b/);
      if (propertyMatch) {
        fields.add(propertyMatch[1]);
        if (pendingPropertyName) {
          fields.add(pendingPropertyName);
          pendingPropertyName = null;
        }
      }
    }

    if (constructorParenDepth > 0 && !/^\s*(?:data\s+)?class\s+\w+\s*\(/.test(line)) {
      constructorParenDepth += countChar(line, "(") - countChar(line, ")");
      if (constructorParenDepth <= 0) {
        constructorParenDepth = 0;
        pendingPropertyName = null;
      }
    }

    braceDepth += countChar(line, "{") - countChar(line, "}");
    if (braceDepth < 0) braceDepth = 0;
  }

  return fields;
}

/**
 * Extract C# record fields as a Map<recordName, Map<wireName, isOptional>>.
 * Each `[JsonPropertyName("wireName")]` property is scoped to the record it
 * belongs to, and its optionality is parsed from `required` vs nullable `?`:
 *   - `public required T Prop` → isOptional = false
 *   - `public T? Prop`         → isOptional = true
 * The canon defines Firestore wire names (camelCase), and the C# models bind
 * those exact names via the attribute, so the attribute value is the comparison
 * key — matching the approach used for Kotlin `@PropertyName` mirrors.
 * Properties without the attribute are not collected.
 *
 * Per-record scoping prevents cross-record masking: a field removed from one
 * record is no longer satisfied by the same field on a sibling record in the
 * same file. Optionality extraction lets the gate detect `required` to nullable
 * drift that a field-name-only check would miss.
 */
function extractCsharpMirrorFields(csharpSource) {
  const source = stripComments(csharpSource);
  const records = new Map();
  const recordRegex =
    /(?:public\s+)?(?:sealed\s+)?(?:record|class)\s+(\w+)\s*(?:\([^)]*\))?\s*\{/g;
  let recordMatch;
  while ((recordMatch = recordRegex.exec(source)) !== null) {
    const recordName = recordMatch[1];
    const bodyStart = recordMatch.index + recordMatch[0].length;
    // Find the matching closing brace for this record body.
    let depth = 1;
    let bodyEnd = bodyStart;
    for (let i = bodyStart; i < source.length && depth > 0; i += 1) {
      if (source[i] === "{") depth += 1;
      else if (source[i] === "}") depth -= 1;
      if (depth === 0) {
        bodyEnd = i;
        break;
      }
    }
    const body = source.slice(bodyStart, bodyEnd);
    const fields = new Map();
    // Match: [JsonPropertyName("wire")] public required? Type? Name { get; init; }
    const fieldRegex =
      /\[JsonPropertyName\s*\(\s*"([^"]+)"\s*\)\s*\]\s*public\s+(required\s+)?(\S+)\s+(\w+)\s*\{\s*get;\s*init;\s*\}/g;
    let fieldMatch;
    while ((fieldMatch = fieldRegex.exec(body)) !== null) {
      const wireName = fieldMatch[1];
      const isRequired = fieldMatch[2] !== undefined;
      // A field is optional when it is NOT `required`. Nullable `?` without
      // `required` is the C# idiom for an optional Firestore field; `required`
      // without `?` is the idiom for a required field. (A `required T?` would
      // be contradictory, so isOptional follows the `required` keyword.)
      fields.set(wireName, !isRequired);
    }
    records.set(recordName, fields);
  }
  return records;
}

/**
 * Resolve a generated canon interface name to the C# record that mirrors it.
 * The primary convention is `Firestore` + interfaceName (e.g. UsageEventDoc →
 * FirestoreUsageEventDoc). When that record is absent — which happens for union
 * variants whose canon splits one model into two TS interfaces but the C# port
 * merges into a single record (e.g. GatewaySignalTransportKeyDeliveryDoc and
 * GatewaySignalAtRestKeyDeliveryDoc both map to FirestoreGatewaySignalKeyDeliveryDoc)
 * — fall back to any record whose field set is a superset of the interface's
 * fields.
 *
 * @param records   Map from extractCsharpMirrorFields
 * @param interfaceName  Generated canon interface name
 * @param genFields  Map of canon fields for the interface
 * @returns the matching record's field Map, or null when no record covers it
 */
function resolveCsharpRecord(records, interfaceName, genFields) {
  const primary = `Firestore${interfaceName}`;
  if (records.has(primary)) return records.get(primary);
  for (const [, fields] of records) {
    let covers = true;
    for (const [field] of genFields) {
      if (!fields.has(field)) {
        covers = false;
        break;
      }
    }
    if (covers) return fields;
  }
  return null;
}

function extractNativeMirrorFields(mirrorSource, language) {
  if (language === "swift") return extractSwiftMirrorFields(mirrorSource);
  if (language === "kotlin") return extractKotlinMirrorFields(mirrorSource);
  if (language === "csharp") return extractCsharpMirrorFields(mirrorSource);
  throw new Error(`unsupported native mirror language: ${language}`);
}

function normalizeMirror(entry) {
  if (typeof entry === "string") return { path: entry };
  return entry;
}

/**
 * Diff one mirror against the target generated interfaces.
 * @returns {string[]} drift tokens — `Interface.field` for a missing field,
 *   `Interface.field#opt` for an optionality mismatch (TS and C# mirrors).
 */
function diffMirror({ generated, mirrorSource, interfaces, compareOptionality, language }) {
  const drift = [];
  const nativeFields = compareOptionality
    ? null
    : extractNativeMirrorFields(mirrorSource, language);
  // C# mirrors use per-record scoping with optionality even when
  // compareOptionality is true, because the per-record Map structure (not a
  // flat Set) is needed to scope fields to the correct record.
  const csharpRecords = language === "csharp"
    ? extractCsharpMirrorFields(mirrorSource)
    : null;
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
    if (compareOptionality && language === "typescript" && !mirrorFields) {
      throw new Error(
        `TS mirror is registered for "${interfaceName}" but does not re-declare it as an interface`
      );
    }
    // C# per-record resolution: find the record that mirrors this interface.
    const csharpRecordFields = csharpRecords
      ? resolveCsharpRecord(csharpRecords, interfaceName, genFields)
      : null;
    if (csharpRecords && !csharpRecordFields) {
      // No C# record covers this interface's fields — every field is drift.
      for (const [field] of genFields) {
        drift.push(`${interfaceName}.${field}`);
      }
      continue;
    }
    for (const [field, optional] of genFields) {
      if (csharpRecords) {
        // C# per-record scoping with optionality comparison.
        if (!csharpRecordFields.has(field)) {
          drift.push(`${interfaceName}.${field}`);
        } else if (csharpRecordFields.get(field) !== optional) {
          drift.push(`${interfaceName}.${field}#opt`);
        }
      } else if (compareOptionality) {
        if (!mirrorFields.has(field)) {
          drift.push(`${interfaceName}.${field}`);
        } else if (mirrorFields.get(field) !== optional) {
          drift.push(`${interfaceName}.${field}#opt`);
        }
      } else if (!nativeFields.has(field)) {
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
 * native (Swift/Kotlin/C#) mirror default to every generated interface in the
 * domain. C# mirrors compare optionality via per-record `required`/`?` parsing,
 * not via `export interface` re-declaration, so they use the full native
 * auto-detect path even when compareOptionality is true.
 */
function resolveInterfaces(entry, generated, mirrorSource, compareOptionality, language) {
  if (Array.isArray(entry.interfaces)) return entry.interfaces;
  const all = generatedInterfaceNames(generated);
  if (!compareOptionality) return all;
  if (language === "csharp") return all;
  return all.filter((name) => extractInterfaceFields(mirrorSource, name));
}

function checkMirror({ domain, generated, entry, compareOptionality, language }) {
  const mirror = normalizeMirror(entry);
  const mirrorSource = readFileSync(join(repoRoot, mirror.path), "utf8");
  const interfaces = resolveInterfaces(
    mirror,
    generated,
    mirrorSource,
    compareOptionality,
    language
  );
  if (interfaces.length === 0) return; // nothing dual-defined to check

  const drift = diffMirror({
    generated,
    mirrorSource,
    interfaces,
    compareOptionality,
    language,
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

function main() {
  const manifest = loadManifest();
  let failures = 0;
  let checked = 0;
  for (const domain of manifest.domains) {
    let generated;
    const failuresBeforeDomain = failures;
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
        language: "swift",
      })),
      ...(domain.kotlinHandMirror ?? []).map((entry) => ({
        entry,
        compareOptionality: false,
        language: "kotlin",
      })),
      ...(domain.tsHandMirror ?? []).map((entry) => ({
        entry,
        compareOptionality: true,
        language: "typescript",
      })),
      ...(domain.csharpHandMirror ?? []).map((entry) => ({
        entry,
        compareOptionality: true,
        language: "csharp",
      })),
    ];

    for (const { entry, compareOptionality, language } of mirrors) {
      checked += 1;
      try {
        checkMirror({ domain, generated, entry, compareOptionality, language });
      } catch (error) {
        failures += 1;
        console.error(String(error.message ?? error));
      }
    }

    if (mirrors.length > 0 && failures === failuresBeforeDomain) {
      console.log(`hand-mirror check passed: ${domain.id} (${mirrors.length} mirror(s))`);
    }
  }

  console.log(`hand-mirror check: ${checked} mirror(s) across all manifest domains`);
  return failures;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const failures = main();
  if (failures > 0) {
    process.exit(1);
  }
}

export {
  diffMirror,
  extractCsharpMirrorFields,
  extractInterfaceFields,
  extractKotlinMirrorFields,
  extractNativeMirrorFields,
  extractSwiftMirrorFields,
  resolveCsharpRecord,
  stripComments,
  stripCommentsAndStrings,
};