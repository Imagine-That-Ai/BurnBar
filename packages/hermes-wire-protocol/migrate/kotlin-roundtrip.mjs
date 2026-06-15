#!/usr/bin/env node
/**
 * Kotlin round-trip prover (mirrors migrate/roundtrip.mjs for Swift).
 *
 * Parses the relay Kotlin sources — both the hand-written HermesRealtimeRelayFrame.kt
 * AND the generated Generated/HermesRealtimeRelayGeneratedTypes.kt (the generatable types
 * were consumed out of the hand-written file in Phase A) — into a per-type model, then
 * cross-references with the canonical schema (relay-message-types.json) to report,
 * per schema type:
 *   - present-in-kotlin? (coverage)
 *   - the EXACT current Kotlin representation per field (type, default, @SerialName,
 *     @EncodeDefault) — the ground truth the emitter must reproduce for byte-faithful
 *     Phase A, and the input to the swiftType->kotlinType reconciliation rules.
 *   - drift vs the schema (date regime, int width, enum-vs-String, missing fields).
 *
 *   node packages/hermes-wire-protocol/migrate/kotlin-roundtrip.mjs            # coverage + drift report
 *   node packages/hermes-wire-protocol/migrate/kotlin-roundtrip.mjs --type X   # dump one type's parsed model
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const IROH = join(HERE, "..", "..", "..", "android", "openburnbar-iroh-relay", "src", "main", "java", "com", "openburnbar", "irohrelay");
const KT = join(IROH, "HermesRealtimeRelayFrame.kt");
// Phase A consumed the generatable types OUT of the hand-written file into Generated/.
// Parse BOTH (zero type-name overlap) so coverage/--type/--faithful see the full universe;
// reading only KT would make every generated type look "missing" and crash --faithful.
const KT_GEN = join(IROH, "Generated", "HermesRealtimeRelayGeneratedTypes.kt");
const SCHEMA = join(HERE, "..", "relay-message-types.json");

const ktSrc = readFileSync(KT, "utf8") + "\n" + readFileSync(KT_GEN, "utf8");
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
      // if a brace body follows the params (nested enums), consume through its matching }
      if ((lines[j+1]||"").trim().startsWith(") {") || (lines[j]||"").trim().endsWith("{")) {}
      let k = j + 1;
      if ((lines[j]||"").includes(") {") || (lines[k]||"").trim() === "" && (lines[k+1]||"").includes("{")) {}
      // simpler: if the close line is ") {" we already have "{"; brace-match forward
      if ((lines[j]||"").includes("{")) {
        let bd = (lines[j].match(/\{/g)||[]).length - (lines[j].match(/\}/g)||[]).length;
        let m = j + 1;
        while (m < lines.length && bd > 0) { bd += (lines[m].match(/\{/g)||[]).length - (lines[m].match(/\}/g)||[]).length; block.push(lines[m]); m++; }
        j = m - 1;
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
if (!process.argv.includes("--overrides") && !process.argv.includes("--faithful")) main();

// --overrides <out.json>: dump per-type Kotlin representation model (the emitter's input).
if (process.argv.includes("--overrides")) {
  const out = process.argv[process.argv.indexOf("--overrides") + 1];
  // GUARD: relay-kotlin-overrides.json is no longer a regenerable extract — it is a
  // HAND-MAINTAINED codegen SOURCE. The generatable types were CONSUMED out of the .kt
  // (Phase A) and the Phase B/C/D representation fixes live ONLY in the curated file.
  // Re-extracting from the (gutted) hand-written .kt would destroy them. Refuse unless
  // the caller explicitly opts in with --force (intentional re-bootstrap only).
  const CURATED = join(HERE, "..", "relay-kotlin-overrides.json");
  if (resolve(out) === resolve(CURATED) && !process.argv.includes("--force")) {
    console.error("REFUSING to overwrite the curated relay-kotlin-overrides.json (hand-maintained codegen SOURCE; re-extraction would destroy Phase B/C/D fixes). Pass --force only to deliberately re-bootstrap.");
    process.exit(2);
  }
  const kt = parseKotlin();
  const schemaNames = new Set(schema.types.map((t) => t.name));
  const model = { $generated: "Bootstrap-only snapshot of the Kotlin representation, extracted from the relay .kt sources — NOT the canonical override file. The canonical packages/hermes-wire-protocol/relay-kotlin-overrides.json is now hand-maintained; do not overwrite it from here.", types: {} };
  for (const t of schema.types) {
    const k = kt[t.name]; if (!k) continue;
    if (t.kind === "enum") {
      model.types[t.name] = { kind: "enum", cases: (k.cases || []).map((c) => ({ id: c.id, serialName: c.serialName })) };
    } else {
      const fmap = {};
      for (const f of (k.fields || [])) fmap[f.name] = { ktType: f.ktType, default: f.default, serialName: f.serialName, encodeDefault: !!f.encodeDefault };
      model.types[t.name] = { kind: "data class", fields: fmap, fieldOrder: (k.fields || []).map((f) => f.name) };
    }
  }
  // record which schema types Kotlin represents (present) vs Kotlin-only
  model.ktOnly = Object.keys(kt).filter((n) => !schemaNames.has(n) && /^Hermes|^PhoneControl/.test(n));
  writeFileSync(out, JSON.stringify(model, null, 2) + "\n");
  console.log(`wrote overrides: ${Object.keys(model.types).length} types -> ${out}`);
  process.exit(0);
}

// --faithful: generate Kotlin via emitKotlinRelayTypes and diff (normalized) per type vs current .kt
if (process.argv.includes("--faithful")) {
  const { emitKotlinRelayTypes, loadKotlinOverrides, kotlinGeneratableTypes } = await import("../relay-types.mjs");
  const overrides = loadKotlinOverrides();
  const { gen, deferred } = kotlinGeneratableTypes(schema, overrides);
  const files = emitKotlinRelayTypes(schema, overrides);
  const genText = Object.values(files)[0];
  const kt = parseKotlin();
  // split generated file into per-type blocks by "@Serializable"
  const norm = (s) => s.split("\n").filter((l) => !/^\s*\/\//.test(l) && !/^\s*\/?\*/.test(l) && l.trim() !== "@Serializable").join("\n").replace(/\s+/g, " ").replace(/,\s*\)/g, ")").trim();
  const genBlocks = {};
  for (const t of gen) {
    const re = t.kind === "enum"
      ? new RegExp(`@Serializable\\nenum class ${t.name} \\{[\\s\\S]*?\\n\\}`, "m")
      : new RegExp(`@Serializable\\ndata class ${t.name}\\b[\\s\\S]*?\\n\\)(?: \\{[\\s\\S]*?\\n\\})?`, "m");
    const m = re.exec(genText); if (m) genBlocks[t.name] = m[0];
  }
  let ok = 0, bad = [];
  for (const t of gen) {
    const k = kt[t.name];
    if (!k) { bad.push(t.name + " (no parsed Kotlin source — is Generated/ present?)"); continue; }
    const cur = (k.raw || []).join("\n");
    const g = genBlocks[t.name] || "";
    if (norm(g) === norm(cur)) ok++; else bad.push(t.name);
  }
  console.log(`Kotlin emitter — generatable: ${gen.length} | faithful: ${ok}/${gen.length} | deferred(drift): ${deferred.length}`);
  if (bad.length) { console.log("MISMATCH:", bad.join(", ")); }
  else console.log("✓ all generatable types byte-faithful (normalized).");
  if (process.argv.includes("--dump") && bad.length) {
    const t = bad[0]; console.log("\n=== GENERATED "+t+" ===\n"+norm(genBlocks[t])+"\n=== CURRENT ===\n"+norm((kt[t].raw||[]).join("\n")));
  }
  process.exit(bad.length ? 1 : 0);
}

// --consume: remove the generatable types' hand-written declarations from the .kt
// (generate-and-consume). Keeps everything else (FrameType, Payload, ControlPayload,
// drift types, PresenceHeartbeat, sealed stream events, Json config, behavior).
if (process.argv.includes("--consume")) {
  const { loadKotlinOverrides, kotlinGeneratableTypes } = await import("../relay-types.mjs");
  const { gen } = kotlinGeneratableTypes(schema, loadKotlinOverrides());
  const genNames = new Set(gen.map((t) => t.name));
  const kt = parseKotlin();
  const srcLines = ktSrc.split("\n");
  // collect [startIdx,endIdx] 0-based inclusive spans to delete, incl annotations/KDoc above
  const spans = [];
  for (const name of genNames) {
    const k = kt[name]; if (!k) continue;
    let start = k.startLine - 1;           // decl line (0-based)
    // walk up over annotations / KDoc / blank-comment lines that belong to this decl
    let s = start - 1;
    while (s >= 0) {
      const l = srcLines[s].trim();
      if (l.startsWith("@") || l.startsWith("/**") || l.startsWith("*") || l.startsWith("*/") || l.startsWith("//") || l === "") s--;
      else break;
    }
    // keep exactly one blank separator above (don't eat the previous type's trailing blank chain beyond one)
    start = s + 1;
    const end = start + (k.startLine - 1 - start) + k.raw.length - 1; // through block end
    spans.push([start, k.startLine - 1 + k.raw.length - 1]);
    // note: recompute end cleanly as decl start + raw length - 1
  }
  // normalize spans: delete from declStart's annotation-start to block end
  const del = [];
  for (const name of genNames) {
    const k = kt[name]; if (!k) continue;
    let declIdx = k.startLine - 1;
    let s = declIdx - 1;
    while (s >= 0) { const l = srcLines[s].trim(); if (l.startsWith("@")||l.startsWith("/**")||l.startsWith("*")||l.startsWith("*/")||l.startsWith("//")||l==="") s--; else break; }
    const startIdx = s + 1;
    const endIdx = declIdx + k.raw.length - 1;
    del.push([startIdx, endIdx]);
  }
  del.sort((a,b)=>a[0]-b[0]);
  const keep = [];
  let cursor = 0;
  for (const [a,b] of del) { for (let i=cursor;i<a;i++) keep.push(srcLines[i]); cursor = b+1; }
  for (let i=cursor;i<srcLines.length;i++) keep.push(srcLines[i]);
  let outText = keep.join("\n").replace(/\n{3,}/g, "\n\n");
  require_fs_write(KT, outText);
  console.log(`consumed ${del.length} generated types; ${srcLines.length} -> ${outText.split("\n").length} LOC in HermesRealtimeRelayFrame.kt`);
  process.exit(0);
}
function require_fs_write(p, t){ writeFileSync(p, t); }
