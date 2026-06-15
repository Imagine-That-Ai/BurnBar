#!/usr/bin/env node
/**
 * P3-G9 migration engine (provenance-kept).
 *
 * Parses hand-written HermesRealtimeRelayTypes.swift into a declarative model,
 * RE-EMITS the data+Codable skeleton from that model, and proves it reproduces
 * the original (normalized for comments + whitespace), per type. The diff is the
 * objective zero-regression gate. Behavior (computed/static/methods) is captured
 * separately for the hand-written +Behavior.swift extension.
 *
 *   node migrate/roundtrip.mjs              # per-type normalized diff report
 *   node migrate/roundtrip.mjs --dump NAME  # print original-skeleton vs generated for one type
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { emitSwiftType } from "./emit-swift-types.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
export const SRC = join(HERE, "..", "..", "..", "OpenBurnBarCore", "Sources", "OpenBurnBarCore", "SharedModels", "HermesRealtimeRelayTypes.swift");

// ── brace-matched top-level splitter ──
function splitTopLevel(src) {
  const lines = src.split("\n");
  const n = lines.length;
  let i = 0;
  const header = [];
  while (i < n && (lines[i].startsWith("import ") || lines[i].trim() === "")) header.push(lines[i++]);
  const declRe = /^(public |private |internal |open |final )*(struct|enum|class|actor|protocol) +([A-Za-z_][A-Za-z0-9_]*)([^{]*)\{/;
  const blocks = [];
  let pending = [];
  while (i < n) {
    const m = declRe.exec(lines[i]);
    if (m) {
      let depth = (lines[i].match(/\{/g) || []).length - (lines[i].match(/\}/g) || []).length;
      const body = [lines[i++]];
      while (i < n && depth > 0) {
        depth += (lines[i].match(/\{/g) || []).length - (lines[i].match(/\}/g) || []).length;
        body.push(lines[i++]);
      }
      blocks.push({ trivia: pending, lines: body, kind: m[2], name: m[3], conformancesRaw: m[4], priv: /^private /.test(lines[body.length ? 0 : 0]) || /private /.test(m[0]) });
      pending = [];
    } else pending.push(lines[i++]);
  }
  return { header, blocks, footer: pending };
}

function parseConformances(raw) {
  const t = raw.replace(/\{\s*$/, "").replace(/:/, "").trim();
  return t ? t.split(",").map((s) => s.trim()).filter(Boolean) : [];
}

// segment a body (decl line .. closing brace) into members at a given indent
function segmentMembers(bodyLines, indent) {
  const inner = bodyLines.slice(1, bodyLines.length - 1);
  const members = [];
  let i = 0, pending = [];
  const startRe = new RegExp(`^${indent}(public |private |internal |static |final |lazy )*(var|let|func|init|enum|struct|case|subscript)\\b`);
  const netDelim = (s) => (s.match(/[{(]/g) || []).length - (s.match(/[})]/g) || []).length;
  while (i < inner.length) {
    if (startRe.test(inner[i])) {
      const first = inner[i];
      // A member spans until braces AND parens balance — handles multi-line inits
      // (`init(` opens a paren) and multi-line `static let x = Foo(...)` factories.
      let depth = netDelim(first);
      const blockOpener = /\b(init|func|subscript|enum|struct)\b/.test(first) || COMPUTED_RE.test(first);
      const ml = [inner[i++]];
      while (i < inner.length && (depth > 0 || (blockOpener && depth === 0 && !ml.join("").includes("{")))) {
        depth += netDelim(inner[i]);
        ml.push(inner[i++]);
      }
      members.push({ trivia: pending, lines: ml });
      pending = [];
    } else pending.push(inner[i++]);
  }
  return members;
}

function parseEnumCases(bodyLines, indent) {
  const members = segmentMembers(bodyLines, indent);
  const cases = [];
  for (const mem of members) {
    const mm = new RegExp(`^${indent}case ([A-Za-z_][A-Za-z0-9_]*)(\\s*=\\s*"([^"]*)")?`).exec(mem.lines[0]);
    if (mm) cases.push({ trivia: mem.trivia, id: mm[1], wire: mm[3], implicit: mm[3] === undefined });
  }
  return cases;
}

const STORED_RE = /^    public var ([A-Za-z_][A-Za-z0-9_]*): (.+?)$/;
const COMPUTED_RE = /^    public (static )?var ([A-Za-z_][A-Za-z0-9_]*): .+\{/;

function classify(first, count) {
  if (/^    (public |private )*enum CodingKeys/.test(first)) return "codingKeys";
  if (/^    public enum |^    public struct /.test(first)) return "nestedType";
  if (/^    public init\(from decoder: Decoder\)/.test(first)) return "customDecode";
  if (/^    public func encode\(to encoder: Encoder\)/.test(first)) return "customEncode";
  if (/^    public init\(/.test(first)) return "memberwiseInit";
  if (COMPUTED_RE.test(first)) return "computed";
  if (/^    public (static )?(func) /.test(first) || /^    public static (let|var) /.test(first)) return "behavior";
  if (count === 1 && /^    public var /.test(first)) return "stored";
  return "unknown";
}

function parseCodingKeysOrdered(memberLines) {
  const arr = [];
  for (const l of memberLines.slice(1, -1)) {
    const mm = /^\s*case ([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*"([^"]*)")?/.exec(l);
    if (mm) arr.push([mm[1], mm[3] !== undefined ? mm[3] : mm[1]]);
  }
  return arr;
}

// Parse the memberwise init signature (single- or multi-line) into {field: defaultExpr}.
function parseInitDefaults(memberLines) {
  const defs = {};
  const text = memberLines.join("\n");
  const open = text.indexOf("(");
  const close = text.lastIndexOf(") {");
  if (open < 0 || close < 0) return defs;
  const sig = text.slice(open + 1, close);
  // split on top-level commas (params here have no nested commas-in-generics with defaults)
  let depth = 0, cur = "", parts = [];
  for (const ch of sig) {
    if (ch === "(" || ch === "[" || ch === "<") depth++;
    else if (ch === ")" || ch === "]" || ch === ">") depth--;
    if (ch === "," && depth === 0) { parts.push(cur); cur = ""; }
    else cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  for (const p of parts) {
    const mm = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*.+?(\s*=\s*(.+))?$/.exec(p.trim());
    if (mm && mm[3] !== undefined) defs[mm[1]] = mm[3].trim();
  }
  return defs;
}

// Join physical lines into logical statements (continuation = unbalanced parens),
// collapsing inner whitespace. Block punctuation `{`/`}`/`} else {` stay separate.
const canon = (s) => s.replace(/\s+/g, " ").replace(/\( /g, "(").replace(/ \)/g, ")").trim();
function logicalLines(rawLines) {
  const out = [];
  let buf = "", depth = 0;
  for (const raw of rawLines) {
    const t = raw.trim();
    if (t === "" || t.startsWith("//")) continue;
    buf = buf ? buf + " " + t : t;
    depth += (t.match(/\(/g) || []).length - (t.match(/\)/g) || []).length;
    if (depth <= 0) { out.push(canon(buf)); buf = ""; depth = 0; }
  }
  if (buf) out.push(canon(buf));
  return out;
}

function parseDecode(memberLines) {
  const fields = {};
  const stragglers = [];
  const ll = logicalLines(memberLines.slice(1, -1)).filter((l) => !/decoder\.container/.test(l));
  const temps = {};      // tempVar -> key (for dual-key)
  let guardKey = null;   // active `if container.contains(.X)` guard
  for (const l of ll) {
    let mm;
    if ((mm = /^if container\.contains\(\.([A-Za-z_]\w*)\) \{$/.exec(l))) { guardKey = mm[1]; continue; }
    if (/^\} else \{$/.test(l) || /^\}$/.test(l) || /^self\.\w+ = nil$/.test(l)) { if (/^\}$/.test(l)) guardKey = null; continue; }
    if ((mm = /^let (\w+) = try container\.decodeIfPresent\((.+?)\.self, forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) { temps[mm[1]] = mm[3]; continue; }
    if ((mm = /^self\.(\w+) = try HermesRealtimeRelayDateCodec\.decode\(container, forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) {
      fields[mm[1]] = guardKey === mm[2] ? { mode: "dateIsoContainsGuard", key: mm[2] } : { mode: "dateIso", key: mm[2] }; guardKey = null; continue;
    }
    if ((mm = /^self\.(\w+) = try container\.decodeIfPresent\((.+?)\.self, forKey: \.([A-Za-z_]\w*)\) \?\? (.+)$/.exec(l))) { fields[mm[1]] = { mode: "ifPresentDefault", type: mm[2], key: mm[3], default: mm[4].trim() }; continue; }
    if ((mm = /^self\.(\w+) = try container\.decodeIfPresent\((.+?)\.self, forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) { fields[mm[1]] = { mode: "ifPresent", type: mm[2], key: mm[3] }; continue; }
    if ((mm = /^self\.(\w+) = try container\.decode\((.+?)\.self, forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) { fields[mm[1]] = { mode: "plain", type: mm[2], key: mm[3] }; continue; }
    if ((mm = /^self\.(\w+) = (\w+(?: \?\? \w+)*) \?\? (.+)$/.exec(l))) {  // dual-key: self.X = tmpA ?? tmpB ?? "fallback"
      const tmpNames = mm[2].split(" ?? ").map((s) => s.trim());
      const keys = tmpNames.map((t) => temps[t]).filter(Boolean);
      if (keys.length >= 2) { fields[mm[1]] = { mode: "dualKey", keys, tempNames: tmpNames, fallback: mm[3].trim() }; continue; }
    }
    stragglers.push(l);
  }
  if (stragglers.length) fields.__straggler__ = stragglers;
  return fields;
}

function parseEncode(memberLines) {
  const fields = {};
  const stragglers = [];
  const ll = logicalLines(memberLines.slice(1, -1)).filter((l) => !/encoder\.container/.test(l));
  let ifLetField = null;
  for (const l of ll) {
    let mm;
    if ((mm = /^if let (\w+) \{$/.exec(l))) { ifLetField = mm[1]; continue; }
    if (/^\}$/.test(l)) { ifLetField = null; continue; }
    if ((mm = /^try container\.encode\(HermesRealtimeRelayDateCodec\.encode\((\w+)\), forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) {
      fields[mm[1]] = ifLetField === mm[1] ? { mode: "dateIsoIfLet", key: mm[2] } : { mode: "dateIso", key: mm[2] }; continue;
    }
    if ((mm = /^try container\.encodeIfPresent\((\w+), forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) { fields[mm[1]] = { mode: "ifPresent", key: mm[2] }; continue; }
    if ((mm = /^try container\.encode\((\w+), forKey: \.([A-Za-z_]\w*)\)$/.exec(l))) {
      if (fields[mm[1]]) { // second encode of same field, different key -> dual-key write
        const prev = fields[mm[1]];
        fields[mm[1]] = { mode: "dualKey", keys: [prev.key, mm[2]] };
      } else fields[mm[1]] = { mode: "plain", key: mm[2] };
      continue;
    }
    stragglers.push(l);
  }
  if (stragglers.length) fields.__straggler__ = stragglers;
  return fields;
}

function parseType(block) {
  const conformances = parseConformances(block.conformancesRaw);
  if (block.kind === "enum") {
    const members = segmentMembers(block.lines, "    ");
    const cases = [], behavior = [], caseMembers = [];
    for (const mem of members) {
      const cm = /^    case ([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*"([^"]*)")?/.exec(mem.lines[0]);
      if (cm) { cases.push({ trivia: mem.trivia, id: cm[1], wire: cm[3], implicit: cm[3] === undefined }); caseMembers.push(mem); }
      else behavior.push({ trivia: mem.trivia, lines: mem.lines });
    }
    return { kind: "enum", name: block.name, conformances, cases, caseMembers, behavior,
             trivia: block.trivia, declLine: block.lines[0], raw: block.lines, namespace: cases.length === 0 };
  }
  const members = segmentMembers(block.lines, "    ");
  const fields = [], behavior = [], nested = [];
  let codingKeysOrdered = null, initDefaults = {}, decode = null, encode = null, skeletonMembers = [];
  for (const mem of members) {
    const cls = classify(mem.lines[0], mem.lines.length);
    if (cls === "stored") { const mm = STORED_RE.exec(mem.lines[0]); fields.push({ trivia: mem.trivia, name: mm[1], swiftType: mm[2].trim(), optional: mm[2].trim().endsWith("?") }); skeletonMembers.push(mem); }
    else if (cls === "nestedType") {
      const sub = { lines: mem.lines.map((s) => s.replace(/^    /, "")), kind: mem.lines[0].includes("enum") ? "enum" : "struct", name: /(?:enum|struct) ([A-Za-z0-9_]+)/.exec(mem.lines[0])[1], conformancesRaw: mem.lines[0].replace(/^.*?(?:enum|struct) [A-Za-z0-9_]+/, ""), trivia: mem.trivia };
      const model = sub.kind === "enum" ? { kind: "enum", name: sub.name, conformances: parseConformances(sub.conformancesRaw), cases: parseEnumCases(sub.lines, "    ") } : null;
      nested.push({ trivia: mem.trivia, model, lines: mem.lines }); skeletonMembers.push(mem);
    }
    else if (cls === "codingKeys") { codingKeysOrdered = parseCodingKeysOrdered(mem.lines); skeletonMembers.push(mem); }
    else if (cls === "memberwiseInit") { initDefaults = parseInitDefaults(mem.lines); skeletonMembers.push(mem); }
    else if (cls === "customDecode") { decode = parseDecode(mem.lines); skeletonMembers.push(mem); }
    else if (cls === "customEncode") { encode = parseEncode(mem.lines); skeletonMembers.push(mem); }
    else behavior.push({ trivia: mem.trivia, lines: mem.lines, cls });
  }
  // attach per-field codable
  for (const f of fields) {
    f.codable = { key: f.name };
    if (decode && decode[f.name]) { f.codable.decode = decode[f.name]; f.codable.key = decode[f.name].key; }
    if (encode && encode[f.name]) f.codable.encode = encode[f.name];
  }
  return { kind: "struct", name: block.name, conformances, trivia: block.trivia, fields, nested,
           codingKeysOrdered, initDefaults, decode, encode, behavior, skeletonMembers,
           declLine: block.lines[0],
           hasCustomCodable: !!(decode || encode || codingKeysOrdered) };
}

// Semantic normalization: drop comment-only lines, then collapse ALL whitespace
// (incl. newlines) to single spaces. Formatting (single- vs multi-line init) is
// irrelevant to generated-code equivalence; only the token stream matters.
function norm(text) {
  return text.split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join(" ").replace(/\s+/g, " ")
    .replace(/\( /g, "(").replace(/ \)/g, ")")   // init line-wrapping is cosmetic
    .trim();
}

// Pull indented nested public types out of a type's text so their *position*
// among stored properties (cosmetic, wire-irrelevant) doesn't fail the compare.
function extractNested(typeText) {
  const lines = typeText.split("\n");
  const body = [], nested = [];
  let i = 0;
  while (i < lines.length) {
    if (/^    public (enum|struct) /.test(lines[i])) {
      let depth = (lines[i].match(/\{/g) || []).length - (lines[i].match(/\}/g) || []).length;
      const blk = [lines[i++]];
      while (i < lines.length && depth > 0) { depth += (lines[i].match(/\{/g) || []).length - (lines[i].match(/\}/g) || []).length; blk.push(lines[i++]); }
      nested.push(blk.join("\n"));
    } else body.push(lines[i++]);
  }
  return { body: body.join("\n"), nested };
}

function originalSkeleton(t) {
  if (t.kind === "enum") return [t.declLine, ...t.caseMembers.flatMap((m) => m.lines), "}"].join("\n");
  const out = [t.declLine];
  for (const mem of t.skeletonMembers) for (const l of mem.lines) out.push(l);
  out.push("}");
  return out.join("\n");
}

function semanticMatch(originalText, generatedText) {
  const og = extractNested(originalText), ge = extractNested(generatedText);
  const bodyOk = norm(og.body) === norm(ge.body);
  const nestedOk = og.nested.map(norm).sort().join("") === ge.nested.map(norm).sort().join("");
  return { ok: bodyOk && nestedOk, bodyOk, nestedOk };
}

export function buildModel() {
  const src = readFileSync(SRC, "utf8");
  const { header, blocks, footer } = splitTopLevel(src);
  return { header, footer, types: blocks.map((b) => ({ ...parseType(b), priv: /private /.test(b.lines[0]) })) };
}

// keep only doc/comment trivia lines (drop blank + MARK separators)
function docTrivia(trivia) {
  return (trivia || []).filter((l) => { const t = l.trim(); return t.startsWith("///") || (t.startsWith("//") && !t.startsWith("// MARK")); });
}

// Map the parsed model to the clean, durable schema shape consumed by the emitter.
export function cleanType(t) {
  if (t.kind === "enum") {
    return { kind: "enum", name: t.name, conformances: t.conformances, namespace: !!t.namespace,
             ...(docTrivia(t.trivia).length ? { doc: docTrivia(t.trivia) } : {}),
             cases: t.cases.map((c) => ({ id: c.id, ...(c.implicit ? {} : { wire: c.wire }), ...(docTrivia(c.trivia).length ? { doc: docTrivia(c.trivia) } : {}) })) };
  }
  return {
    kind: "struct", name: t.name, conformances: t.conformances, hasCustomCodable: t.hasCustomCodable,
    ...(docTrivia(t.trivia).length ? { doc: docTrivia(t.trivia) } : {}),
    fields: t.fields.map((f) => ({ name: f.name, swiftType: f.swiftType,
      ...(docTrivia(f.trivia).length ? { doc: docTrivia(f.trivia) } : {}),
      codable: f.codable })),
    initDefaults: t.initDefaults,
    ...(t.codingKeysOrdered ? { codingKeysOrdered: t.codingKeysOrdered } : {}),
    nested: t.nested.map((nf) => ({ model: cleanType(nf.model) })),
  };
}

// Reconstruct the emitter-shape from a clean schema type (inverse of cleanType).
export function hydrate(s) {
  if (s.kind === "enum") return { kind: "enum", name: s.name, conformances: s.conformances, namespace: s.namespace,
    cases: s.cases.map((c) => ({ id: c.id, wire: c.wire, implicit: c.wire === undefined, trivia: c.doc || [] })) };
  const fields = s.fields.map((f) => ({ name: f.name, swiftType: f.swiftType, optional: f.swiftType.endsWith("?"), trivia: f.doc || [], codable: f.codable }));
  return { kind: "struct", name: s.name, conformances: s.conformances, hasCustomCodable: s.hasCustomCodable,
    fields, initDefaults: s.initDefaults, codingKeysOrdered: s.codingKeysOrdered,
    nested: (s.nested || []).map((n) => ({ model: hydrate(n.model) })),
    decode: s.hasCustomCodable ? {} : null, encode: fields.some((f) => f.codable && f.codable.encode) ? {} : null };
}

function main() {
  const { types } = buildModel();
  const writeArg = process.argv.indexOf("--write-schema");
  if (writeArg > -1) {
    // Exclude the frame/protocol layer (owned by protocol.json, parity-gated) and
    // the verbatim helpers (namespace, DateCodec). Only payload types are generated.
    const FRAME_OWNED = new Set(["HermesRealtimeRelayFrameType"]);
    const dataTypes = types.filter((t) => !t.priv && !(t.kind === "enum" && t.namespace) && !FRAME_OWNED.has(t.name));
    const schema = { $generated: "Canonical Hermes relay payload message types — single source of truth for Swift/Kotlin codegen.",
                     schemaVersion: 1, types: dataTypes.map(cleanType) };

    writeFileSync(process.argv[writeArg + 1], JSON.stringify(schema, null, 2) + "\n");
    console.log(`wrote ${schema.types.length} types to ${process.argv[writeArg + 1]}`);
    return;
  }
  const verifyArg = process.argv.indexOf("--verify-schema");
  if (verifyArg > -1) {

    const schema = JSON.parse(readFileSync(process.argv[verifyArg + 1], "utf8"));
    const liveByName = new Map(types.map((t) => [t.name, t]));
    let ok = 0, bad = [];
    for (const s of schema.types) {
      const live = liveByName.get(s.name);
      if (semanticMatch(originalSkeleton(live), emitSwiftType(hydrate(s))).ok) ok++; else bad.push(s.name);
    }
    console.log(`schema round-trip: ${ok}/${schema.types.length} faithful`);
    if (bad.length) console.log("MISMATCH: " + bad.join(", ")); else console.log("✓ standalone schema is faithful.");
    return;
  }
  const dumpArg = process.argv.indexOf("--dump");
  if (dumpArg > -1) {
    const t = types.find((x) => x.name === process.argv[dumpArg + 1]);
    console.log("===== ORIGINAL SKELETON =====\n" + norm(originalSkeleton(t)));
    console.log("\n===== GENERATED =====\n" + norm(emitSwiftType(t)));
    return;
  }
  let ok = 0, mismatch = [], errored = [], skipped = [];
  for (const t of types) {
    if (t.priv) { skipped.push(t.name + "(helper)"); continue; }   // DateCodec: verbatim
    if (t.kind === "enum" && t.namespace) { skipped.push(t.name + "(namespace)"); continue; } // constants → behavior
    let gen;
    try { gen = emitSwiftType(t); } catch (e) { errored.push(`${t.name}: ${e.message}`); continue; }
    if (semanticMatch(originalSkeleton(t), gen).ok) ok++;
    else mismatch.push(t.name);
  }
  console.log(`types: ${types.length}  |  skipped(verbatim): ${skipped.length} [${skipped.join(", ")}]`);
  console.log(`semantically faithful: ${ok}/${types.length - skipped.length}`);
  if (errored.length) { console.log(`\nEMIT ERRORS (${errored.length}):`); errored.forEach((e) => console.log("  " + e)); }
  if (mismatch.length) { console.log(`\nMISMATCH (${mismatch.length}): ${mismatch.join(", ")}`); console.log(`\n→ inspect: node migrate/roundtrip.mjs --dump <Name>`); }
  else if (!errored.length) console.log("\n✓ ALL PAYLOAD TYPES ROUND-TRIP — schema+emitter faithful.");
}

main();
