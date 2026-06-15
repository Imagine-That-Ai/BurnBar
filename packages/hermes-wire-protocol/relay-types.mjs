#!/usr/bin/env node
/**
 * Hermes relay PAYLOAD message types — schema-driven codegen.
 *
 * `relay-message-types.json` is the single source of truth for the rich relay
 * payload types (frames + transport constants live in protocol.json). This module
 * validates that schema and emits the Swift data + Codable conformances, so the
 * ~60 wire types are defined ONCE and can never drift across Swift / Kotlin.
 *
 * Three date regimes are first-class and PER-FIELD (never a global default):
 *   iso                    decode + encode via HermesRealtimeRelayDateCodec (ISO-8601, ms)
 *   numeric                Swift-synthesized Codable (JSON number both directions)
 *   numericEncodeIsoDecode tolerate an ISO string on decode, re-emit a number
 *
 * Behavior (computed members, factories) and the shared DateCodec helper are
 * hand-written in SharedModels/HermesRealtimeRelayTypes+Behavior.swift; only the
 * data shapes are generated. Pure Node, no dependencies.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = join(HERE, "relay-message-types.json");
const SWIFT_GEN_DIR = join(HERE, "..", "..", "OpenBurnBarCore", "Sources", "OpenBurnBarCore", "SharedModels", "Generated");

export const DATE_CODEC = "HermesRealtimeRelayDateCodec";
// Deterministic file/domain order (stable generated output → clean drift gate).
const DOMAIN_ORDER = ["Control", "RemoteUnlock", "SystemPermission", "Media", "Envelope"];

export function loadRelayTypes() {
  return JSON.parse(readFileSync(SCHEMA_PATH, "utf8"));
}

export function domainOf(name) {
  if (/RemoteUnlock|MacLockState/.test(name)) return "RemoteUnlock";
  if (/SystemPermission/.test(name)) return "SystemPermission";
  if (/Payload$|ErrorCode$|AgentContextTarget$/.test(name)) return "Envelope";
  if (/Media|Focus|Normalized|Mirror|Call|LongTermReference|PresenceHeartbeat|VideoCodec|Datagram|Streaming|AttachmentManifest|AgentTerminal/.test(name)) return "Media";
  return "Control";
}

/** Validate the relay-types schema; throw on any structural problem. */
export function validateRelayTypes(schema) {
  const errors = [];
  if (schema.schemaVersion !== 1) errors.push(`schemaVersion must be 1, got ${schema.schemaVersion}`);
  const names = new Set();
  const scalar = new Set(["string", "bool", "int", "i64", "u32", "u64", "u8", "double", "date", "data"]);
  const collect = (t) => { if (names.has(t.name)) errors.push(`duplicate type ${t.name}`); names.add(t.name); (t.nested || []).forEach((n) => names.add(n.model.name)); };
  (schema.types || []).forEach(collect);
  const known = new Set([...names]);
  const checkType = (raw) => {
    const base = raw.replace(/\?$/, "").replace(/^\[/, "").replace(/\]$/, "");
    if (scalar.has(base) || base === "Date" || /^[A-Z]/.test(base) || base.includes(":")) return; // scalar, Date, named, or dictionary
  };
  for (const t of schema.types || []) {
    if (t.kind === "enum") {
      if (!t.cases || !t.cases.length) errors.push(`${t.name}: enum needs cases`);
      const w = new Set();
      for (const c of t.cases || []) { const wire = c.wire ?? c.id; if (w.has(wire)) errors.push(`${t.name}.${c.id}: duplicate wire ${wire}`); w.add(wire); }
    } else if (t.kind === "struct") {
      for (const f of t.fields || []) {
        checkType(f.swiftType);
        const d = f.codable && f.codable.decode;
        if (d && d.mode === undefined) errors.push(`${t.name}.${f.name}: decode missing mode`);
        // date-regime sanity: a custom date field must use a known date mode
        if (/\bDate\b/.test(f.swiftType) && t.hasCustomCodable && d && !["dateIso", "dateIsoContainsGuard"].includes(d.mode))
          errors.push(`${t.name}.${f.name}: Date field with custom Codable must declare a date decode mode (got ${d.mode})`);
      }
    } else errors.push(`${t.name}: unknown kind ${t.kind}`);
  }
  if (errors.length) throw new Error(`relay-message-types.json invalid:\n  - ${errors.join("\n  - ")}`);
  return schema;
}

// ── emit ──────────────────────────────────────────────────────────────────
const I1 = "    ", I2 = "        ", I3 = "            ";
const base = (t) => t.replace(/\?$/, "");
const doc = (lines) => (lines || []).map((l) => l).filter((l) => l.trim() !== "");

function emitEnum(t, indent = "") {
  const out = [`${indent}public enum ${t.name}: ${t.conformances.join(", ")} {`];
  for (const c of t.cases) {
    for (const d of doc(c.doc)) out.push(d);
    out.push(c.wire === undefined ? `${indent}${I1}case ${c.id}` : `${indent}${I1}case ${c.id} = "${c.wire}"`);
  }
  out.push(`${indent}}`);
  return out.join("\n");
}

function emitDecode(t) {
  const out = [`${I1}public init(from decoder: Decoder) throws {`, `${I2}let container = try decoder.container(keyedBy: CodingKeys.self)`];
  for (const f of t.fields) {
    const d = f.codable.decode, key = f.codable.key ?? f.name, ty = base(f.swiftType);
    if (d.mode === "plain") out.push(`${I2}self.${f.name} = try container.decode(${d.type || ty}.self, forKey: .${key})`);
    else if (d.mode === "ifPresent") out.push(`${I2}self.${f.name} = try container.decodeIfPresent(${d.type || ty}.self, forKey: .${key})`);
    else if (d.mode === "ifPresentDefault") out.push(`${I2}self.${f.name} = try container.decodeIfPresent(${d.type || ty}.self, forKey: .${key}) ?? ${d.default}`);
    else if (d.mode === "dateIso") out.push(`${I2}self.${f.name} = try ${DATE_CODEC}.decode(container, forKey: .${key})`);
    else if (d.mode === "dateIsoContainsGuard") out.push(`${I2}if container.contains(.${d.key}) {`, `${I3}self.${f.name} = try ${DATE_CODEC}.decode(container, forKey: .${d.key})`, `${I2}} else {`, `${I3}self.${f.name} = nil`, `${I2}}`);
    else if (d.mode === "dualKey") { d.tempNames.forEach((tmp, k) => out.push(`${I2}let ${tmp} = try container.decodeIfPresent(${ty}.self, forKey: .${d.keys[k]})`)); out.push(`${I2}self.${f.name} = ${d.tempNames.join(" ?? ")} ?? ${d.fallback}`); }
    else throw new Error(`${t.name}.${f.name}: bad decode ${d.mode}`);
  }
  out.push(`${I1}}`);
  return out.join("\n");
}

function emitEncode(t) {
  const out = [`${I1}public func encode(to encoder: Encoder) throws {`, `${I2}var container = encoder.container(keyedBy: CodingKeys.self)`];
  for (const f of t.fields) {
    const e = f.codable.encode; if (!e) continue;
    const key = e.key ?? f.name;
    if (e.mode === "plain") out.push(`${I2}try container.encode(${f.name}, forKey: .${key})`);
    else if (e.mode === "ifPresent") out.push(`${I2}try container.encodeIfPresent(${f.name}, forKey: .${key})`);
    else if (e.mode === "dateIso") out.push(`${I2}try container.encode(${DATE_CODEC}.encode(${f.name}), forKey: .${key})`);
    else if (e.mode === "dateIsoIfLet") out.push(`${I2}if let ${f.name} {`, `${I3}try container.encode(${DATE_CODEC}.encode(${f.name}), forKey: .${key})`, `${I2}}`);
    else if (e.mode === "dualKey") e.keys.forEach((kk) => out.push(`${I2}try container.encode(${f.name}, forKey: .${kk})`));
    else throw new Error(`${t.name}.${f.name}: bad encode ${e.mode}`);
  }
  out.push(`${I1}}`);
  return out.join("\n");
}

function emitStruct(t) {
  const out = [`public struct ${t.name}: ${t.conformances.join(", ")} {`];
  for (const f of t.fields) { for (const d of doc(f.doc)) out.push(d); out.push(`${I1}public var ${f.name}: ${f.swiftType}`); }
  for (const n of t.nested || []) out.push(emitEnum(n.model, I1));
  // memberwise init (declared field order; defaults from schema)
  const params = t.fields.map((f) => `${I2}${f.name}: ${f.swiftType}${t.initDefaults && t.initDefaults[f.name] !== undefined ? ` = ${t.initDefaults[f.name]}` : ""}`);
  out.push(`${I1}public init(`, params.join(",\n"), `${I1}) {`, ...t.fields.map((f) => `${I2}self.${f.name} = ${f.name}`), `${I1}}`);
  if (t.hasCustomCodable) {
    if (t.codingKeysOrdered) {
      out.push(`${I1}private enum CodingKeys: String, CodingKey {`);
      for (const [field, wire] of t.codingKeysOrdered) out.push(wire === field ? `${I2}case ${field}` : `${I2}case ${field} = "${wire}"`);
      out.push(`${I1}}`);
    }
    if (t.fields.some((f) => f.codable && f.codable.decode)) out.push(emitDecode(t));
    if (t.fields.some((f) => f.codable && f.codable.encode)) out.push(emitEncode(t));
  }
  out.push("}");
  return out.join("\n");
}

function emitType(t) {
  const body = t.kind === "enum" ? emitEnum(t) : emitStruct(t);
  const d = doc(t.doc);
  return d.length ? d.join("\n") + "\n" + body : body;
}

const HEADER = (domain) =>
  `// GENERATED by packages/hermes-wire-protocol/codegen.mjs — DO NOT EDIT.\n` +
  `// Source of truth: packages/hermes-wire-protocol/relay-message-types.json. Run \`node codegen.mjs\`.\n` +
  `//\n// Hermes realtime-relay payload types — ${domain} domain. The wire contract is\n` +
  `// schema-locked across Swift / Kotlin so iOS·macOS ↔ Android can never drift.\n` +
  `// Behavior (computed members, factories) lives in HermesRealtimeRelayTypes+Behavior.swift.\n\n` +
  `import Foundation\n`;

/** Emit the domain-split Swift files: { absolutePath: content }. */
export function emitSwiftRelayTypes(schema) {
  const byDomain = {};
  for (const t of schema.types) (byDomain[domainOf(t.name)] ??= []).push(t);
  const files = {};
  for (const domain of DOMAIN_ORDER) {
    const ts = byDomain[domain] || [];
    if (!ts.length) continue;
    const body = ts.map(emitType).join("\n\n");
    files[join(SWIFT_GEN_DIR, `HermesRealtimeRelay${domain}.swift`)] = HEADER(domain) + "\n" + body + "\n";
  }
  return files;
}

// ── Kotlin (android/openburnbar-iroh-relay) ──────────────────────────────────
// Generates kotlinx.serialization data classes/enums for the relay payload types.
// The schema drives STRUCTURE (which types, field order, wire keys, date regime);
// `relay-kotlin-overrides.json` (parsed once from the hand-written Kotlin) supplies
// Kotlin-specific REPRESENTATION (int widths Long/Int, enum-ref-as-String, defaults,
// @EncodeDefault set) so generation is byte-faithful. Phase A emits only types whose
// schema field-set exactly matches Kotlin's (zero wire change); mismatch types
// (additive gaps, dual-key, date-drift) stay hand-written until Phases B–D.
const KOTLIN_GEN_DIR = join(HERE, "..", "..", "android", "openburnbar-iroh-relay", "src", "main", "java", "com", "openburnbar", "irohrelay", "Generated");
const KOTLIN_OVERRIDES_PATH = join(HERE, "relay-kotlin-overrides.json");

export function loadKotlinOverrides() {
  return JSON.parse(readFileSync(KOTLIN_OVERRIDES_PATH, "utf8"));
}

// lowerCamelCase -> SCREAMING_SNAKE (local copy to avoid a circular import on codegen.mjs)
function screamingSnake(id) { return id.replace(/([A-Z])/g, "_$1").toUpperCase(); }

const KI = "    ";
function ktDoc(lines) { return doc(lines).map((l) => l.replace(/^\s*\/\/\/?\s?/, "    // ")); }

function emitKotlinEnum(t, ov) {
  const out = ["@Serializable", `enum class ${t.name} {`];
  // The wire string (@SerialName) is canonical and comes from the schema. The Kotlin
  // constant NAME is a representation choice carried in the override (e.g. FILEVAULT_SSH,
  // not the acronym-mangled FILE_VAULT_S_S_H screamingSnake would derive). Match schema
  // case -> override constant by wire string; fall back to screamingSnake only if absent.
  const wireToConst = new Map((ov.cases || []).map((c) => [c.serialName ?? c.id, c.id]));
  t.cases.forEach((c, i) => {
    const sn = c.wire ?? c.id;
    const constName = wireToConst.get(sn) ?? screamingSnake(c.id).replace(/^_/, "");
    out.push(`${KI}@SerialName("${sn}")`);
    out.push(`${KI}${constName},`);
    if (i < t.cases.length - 1) out.push("");
  });
  out.push("}");
  return out.join("\n");
}

function emitKotlinNestedEnum(model, indent) {
  const out = [`${indent}@Serializable`, `${indent}enum class ${model.name} {`];
  model.cases.forEach((c, i) => {
    const screaming = screamingSnake(c.id).replace(/^_/, "");
    out.push(`${indent}${KI}@SerialName("${c.wire ?? c.id}")`);
    out.push(`${indent}${KI}${screaming},`);
    if (i < model.cases.length - 1) out.push("");
  });
  out.push(`${indent}}`);
  return out.join("\n");
}

function emitKotlinStruct(t, ov) {
  const out = ["@Serializable", `data class ${t.name}(`];
  // field order follows the schema (== Kotlin order for the byte-faithful set)
  for (const f of t.fields) {
    const o = (ov.fields || {})[f.name];
    if (!o) throw new Error(`${t.name}.${f.name}: no Kotlin override`);
    if (o.serialName && o.serialName !== f.name) out.push(`${KI}@SerialName("${o.serialName}")`);
    if (o.encodeDefault) { out.push(`${KI}@OptIn(ExperimentalSerializationApi::class)`); out.push(`${KI}@EncodeDefault`); }
    const def = o.default !== undefined ? ` = ${o.default}` : "";
    out.push(`${KI}val ${f.name}: ${o.ktType}${def},`);
  }
  // Only nest an enum the Kotlin field actually references by its nested name.
  // (InputIntent.Kind is HOISTED in Kotlin to top-level HermesRealtimeRelayInputIntentKind
  //  and kept hand-written, so its data class must not re-nest it.)
  const fieldTypes = new Set(t.fields.map((f) => ((ov.fields || {})[f.name]?.ktType || "").replace(/\?$/, "")));
  const nested = (t.nested || []).filter((n) => n.model && fieldTypes.has(n.model.name));
  if (nested.length) {
    out.push(") {");
    nested.forEach((n, i) => { if (i > 0) out.push(""); out.push(emitKotlinNestedEnum(n.model, KI)); });
    out.push("}");
  } else {
    out.push(")");
  }
  return out.join("\n");
}

const KOTLIN_HEADER =
  "// GENERATED by packages/hermes-wire-protocol/codegen.mjs — DO NOT EDIT.\n" +
  "// Source of truth: packages/hermes-wire-protocol/relay-message-types.json\n" +
  "// (+ relay-kotlin-overrides.json for Kotlin representation). Run `node codegen.mjs`.\n" +
  "//\n// Hermes realtime-relay payload types — schema-locked across Swift / Kotlin so\n" +
  "// iOS·macOS ↔ Android can never drift. Frame enum, Json config, sealed stream\n" +
  "// events, and behavior stay hand-written in HermesRealtimeRelayFrame.kt.\n\n" +
  "package com.openburnbar.irohrelay\n\n" +
  "import kotlinx.serialization.EncodeDefault\n" +
  "import kotlinx.serialization.ExperimentalSerializationApi\n" +
  "import kotlinx.serialization.SerialName\n" +
  "import kotlinx.serialization.Serializable\n";

// A schema type is byte-faithfully generatable iff its field-set exactly equals
// Kotlin's (no additive gap / dual-key / count mismatch). Mismatch types stay
// hand-written for the staged drift-fix phases.
export function kotlinGeneratableTypes(schema, overrides) {
  const gen = [], deferred = [];
  for (const t of schema.types) {
    const ov = overrides.types[t.name];
    if (!ov) { deferred.push([t.name, "not-in-kotlin"]); continue; }
    if (t.kind === "enum") {
      // Generatable iff the WIRE-STRING sets match (the @SerialName is the cross-language
      // contract). The Kotlin constant name is representation, captured in the override —
      // so acronym enums (FILEVAULT_SSH, OPENBURNBAR_VIRTUAL_HID) generate cleanly.
      const schemaWire = t.cases.map((c) => c.wire ?? c.id).sort();
      const ktWire = (ov.cases || []).map((c) => c.serialName ?? c.id).sort();
      if (JSON.stringify(schemaWire) === JSON.stringify(ktWire)) gen.push(t); else deferred.push([t.name, "enum-case-mismatch"]);
    } else {
      const schemaFields = t.fields.map((f) => f.name).sort();
      const ktFields = (ov.fieldOrder || []).slice().sort();
      if (JSON.stringify(schemaFields) === JSON.stringify(ktFields)) gen.push(t); else deferred.push([t.name, "field-set-mismatch"]);
    }
  }
  return { gen, deferred };
}

/** Emit the generated Kotlin file: { absolutePath: content }. */
export function emitKotlinRelayTypes(schema, overrides) {
  const { gen } = kotlinGeneratableTypes(schema, overrides);
  const body = gen.map((t) => {
    const ov = overrides.types[t.name];
    return t.kind === "enum" ? emitKotlinEnum(t, ov) : emitKotlinStruct(t, ov);
  }).join("\n\n");
  return { [join(KOTLIN_GEN_DIR, "HermesRealtimeRelayGeneratedTypes.kt")]: KOTLIN_HEADER + "\n" + body + "\n" };
}
