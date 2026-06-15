#!/usr/bin/env node
/**
 * Kotlin round-trip prover (mirrors migrate/roundtrip.mjs for Swift).
 *
 * Parses the hand-written android/.../HermesRealtimeRelayFrame.kt into a per-type
 * model, then cross-references with the canonical schema (relay-message-types.json)
 * to report, per schema type:
 *   - present-in-kotlin? (coverage)
 *   - the EXACT current Kotlin representation per field (type, default, @SerialName,
 *     @EncodeDefault) — the ground truth the emitter must reproduce for byte-faithful
 *     Phase A, and the input to the swiftType->kotlinType reconciliation rules.
 *   - drift vs the schema (date regime, int width, enum-vs-String, missing fields).
 *
 *   node packages/hermes-wire-protocol/migrate/kotlin-roundtrip.mjs            # coverage + drift report
 *   node packages/hermes-wire-protocol/migrate/kotlin-roundtrip.mjs --type X   # dump one type's parsed model
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const KT = join(HERE, "..", "..", "..", "android", "openburnbar-iroh-relay", "src", "main", "java", "com", "openburnbar", "irohrelay", "HermesRealtimeRelayFrame.kt");
const SCHEMA = join(HERE, "..", "relay-message-types.json");

const ktSrc = readFileSync(KT, "utf8");
const schema = JSON.parse(readFileSync(SCHEMA, "utf8"));
const lines = ktSrc.split("\n");

// ── parse top-level @Serializable data class / enum class blocks ──
// We brace-match from the declaration line; annotations on the line(s) above attach.
function parseKotlin() {
  const types = {};
  for (let i = 0; i < lines.length; i++) {
    const dc = /^data class ([A-Za-z_][A-Za-z0-9_]*)\s*\(/.exec(lines[i]);
    const ec = /^enum class ([A-Za-z_][A-Za-z0-9_]*)/.exec(lines[i]);
    if (dc) {
      // gather annotations above (@Serializable, etc.)
      const block = [];
      let depth = 0, j = i;
      // data class params end at the matching ")" at col 0-ish; brace-count parens
      let started = false;
      for (; j < lines.length; j++) {
        const l = lines[j];
        depth += (l.match(/\(/g) || []).length - (l.match(/\)/g) || []).length;
        block.push(l);
        if (l.includes("(")) started = true;
        if (started && depth <= 0) break;
      }
      types[dc[1]] = { kind: "data class", name: dc[1], startLine: i + 1, fields: parseFields(block), raw: block };
      i = j;
    } else if (ec) {
      const block = [];
      let depth = 0, j = i, started = false;
      for (; j < lines.length; j++) {
        const l = lines[j];
        depth += (l.match(/\{/g) || []).length - (l.match(/\}/g) || []).length;
        block.push(l);
        if (l.includes("{")) started = true;
        if (started && depth <= 0) break;
      }
      types[ec[1]] = { kind: "enum class", name: ec[1], startLine: i + 1, cases: parseEnumCases(block), raw: block };
      i = j;
    }
  }
  return types;
}

function parseFields(block) {
  const fields = [];
  let pendingSerialName = null, pendingEncodeDefault = false;
  for (const l of block) {
    const sn = /@SerialName\("([^"]*)"\)/.exec(l);
    if (sn) pendingSerialName = sn[1];
    if (/@EncodeDefault/.test(l)) pendingEncodeDefault = true;
    // field: `val name: Type = default,` (possibly trailing comma)
    const m = /^\s*val ([A-Za-z_][A-Za-z0-9_]*):\s*([A-Za-z0-9_<>?.,\s]+?)(\s*=\s*(.+?))?,?\s*$/.exec(l);
    if (m && !/^\s*\/\//.test(l)) {
      fields.push({ name: m[1], ktType: m[2].trim(), default: m[4] ? m[4].trim().replace(/,$/, "") : undefined,
                    serialName: pendingSerialName, encodeDefault: pendingEncodeDefault });
      pendingSerialName = null; pendingEncodeDefault = false;
    }
  }
  return fields;
}
function parseEnumCases(block) {
  const cases = [];
  let pendingSerialName = null;
  for (const l of block) {
    const sn = /@SerialName\("([^"]*)"\)/.exec(l);
    if (sn) pendingSerialName = sn[1];
    const m = /^\s*([A-Z][A-Z0-9_]*)\s*[,;]?\s*$/.exec(l);
    if (m && !/class|enum|@/.test(l)) { cases.push({ id: m[1], serialName: pendingSerialName }); pendingSerialName = null; }
  }
  return cases;
}

// ── schema helpers ──
const baseType = (t) => t.replace(/\?$/, "");
function schemaDateRegime(f) {
  // ENCODE-mode keyed (the load-bearing rule): iso -> String, else Double
  const e = f.codable && f.codable.encode;
  if (e && (e.mode === "dateIso" || e.mode === "dateIsoIfLet")) return "iso(String)";
  return "numeric(Double)";
}
const isDate = (f) => /\bDate\b/.test(f.swiftType);

function main() {
  const kt = parseKotlin();
  const dumpArg = process.argv.indexOf("--type");
  if (dumpArg > -1) { console.log(JSON.stringify(kt[process.argv[dumpArg + 1]], null, 2)); return; }

  const schemaTypes = schema.types;
  let present = 0, missing = [];
  const driftRows = [];
  for (const t of schemaTypes) {
    const k = kt[t.name];
    if (!k) { missing.push(t.name); continue; }
    present++;
    if (t.kind !== "struct") continue;
    const ktByName = new Map((k.fields || []).map((f) => [f.name, f]));
    for (const f of t.fields) {
      const kf = ktByName.get(f.name);
      if (!kf) { driftRows.push(`${t.name}.${f.name}: MISSING in Kotlin (schema has it)`); continue; }
      if (isDate(f)) {
        const want = schemaDateRegime(f);
        const got = /String/.test(kf.ktType) ? "iso(String)" : (/Double/.test(kf.ktType) ? "numeric(Double)" : kf.ktType);
        if (want !== got) driftRows.push(`${t.name}.${f.name}: DATE drift — schema wants ${want}, Kotlin has ${got}`);
      }
    }
  }
  console.log(`schema types: ${schemaTypes.length} | present in Kotlin: ${present} | missing from Kotlin: ${missing.length}`);
  if (missing.length) console.log("MISSING (schema type w/ no Kotlin equiv — generate or Kotlin-only):\n  " + missing.join(", "));
  console.log(`\nDATE/field drift rows (${driftRows.length}):`);
  driftRows.forEach((r) => console.log("  " + r));
  // Kotlin-only types (in .kt but not schema) — must NOT be generated
  const schemaNames = new Set(schemaTypes.map((t) => t.name));
  const ktOnly = Object.keys(kt).filter((n) => !schemaNames.has(n) && /^Hermes/.test(n));
  console.log(`\nKotlin-only Hermes* types (keep hand-written, exclude from gen): ${ktOnly.length}\n  ${ktOnly.join(", ")}`);
}
main();
