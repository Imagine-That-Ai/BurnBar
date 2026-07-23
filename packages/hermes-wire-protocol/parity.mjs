#!/usr/bin/env node
/**
 * Parity gate for the Hermes/iroh wire protocol.
 *
 * Parses every HAND-WRITTEN surface that speaks the protocol and asserts each
 * one matches protocol.json exactly. This is the enforcement that makes
 * cross-language drift impossible WITHOUT requiring the Swift / Kotlin
 * toolchains in CI — it is pure text parsing over the production source:
 *
 *   - Swift  HermesRealtimeRelayFrameType  (OpenBurnBarCore) — full 41-frame set.
 *   - Kotlin HermesRealtimeRelayFrameType  (android)         — full 41-frame set.
 *   - TS     FRAME_TYPES                    (relay protocol.ts) — relayAccepted subset.
 *   - Rust   OPENBURNBAR_ALPN / MAX_FRAME_BYTES (openburnbar-iroh) — wire constants.
 *   - Swift  IrohRelayProtocol             — alpn / maxFrameBytes / lengthPrefix.
 *   - Kotlin IrohRelayProtocol             — alpn / maxFrameBytes / lengthPrefix.
 *
 * Run: node parity.mjs   (exits non-zero with a detailed report on any drift)
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadProtocol, validateProtocol } from "./codegen.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");

const PATHS = {
  swiftEnum: join(ROOT, "OpenBurnBarCore/Sources/OpenBurnBarKernelModels/SharedModels/HermesRealtimeRelayFrameType.swift"),
  kotlinEnum: join(ROOT, "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/HermesRealtimeRelayFrame.kt"),
  tsRelay: join(ROOT, "services/hermes-realtime-relay/src/protocol.ts"),
  generatedTs: join(ROOT, "services/hermes-realtime-relay/src/generated/wireProtocol.ts"),
  rust: join(ROOT, "crates/openburnbar-iroh/src/lib.rs"),
  swiftIroh: join(ROOT, "OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayProtocol.swift"),
  kotlinIroh: join(ROOT, "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/IrohRelayProtocol.kt"),
};

function read(p) {
  return readFileSync(p, "utf8");
}

/** Evaluate a simple integer RHS like `524288`, `512 * 1024`, `512*1024`. */
function evalIntExpr(expr) {
  const m = String(expr).trim().match(/^(\d+)\s*(?:\*\s*(\d+))?$/);
  if (!m) return NaN;
  return m[2] ? Number(m[1]) * Number(m[2]) : Number(m[1]);
}

/** Extract the body of the first `{...}` block following a header match. */
function blockAfter(src, headerRegex) {
  const m = src.match(headerRegex);
  if (!m) return null;
  const start = src.indexOf("{", m.index);
  if (start === -1) return null;
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) return src.slice(start + 1, i);
    }
  }
  return null;
}

// ── parsers ──────────────────────────────────────────────────────────────────

/** Swift enum -> [{ id, wire }] (implicit raw value => wire === id). */
export function parseSwiftFrames(src) {
  const body = blockAfter(src, /enum\s+HermesRealtimeRelayFrameType\s*:/);
  if (body === null) throw new Error("Swift: HermesRealtimeRelayFrameType enum not found");
  const frames = [];
  for (const line of body.split("\n")) {
    const m = line.match(/^\s*case\s+([A-Za-z0-9]+)\s*(?:=\s*"([^"]+)")?\s*$/);
    if (m) frames.push({ id: m[1], wire: m[2] ?? m[1] });
  }
  return frames;
}

/** Kotlin enum -> [{ id (screaming snake), wire }]. */
export function parseKotlinFrames(src) {
  const body = blockAfter(src, /enum\s+class\s+HermesRealtimeRelayFrameType/);
  if (body === null) throw new Error("Kotlin: HermesRealtimeRelayFrameType enum not found");
  const frames = [];
  const re = /@SerialName\("([^"]+)"\)\s*([A-Z][A-Z0-9_]*)\s*,/g;
  let m;
  while ((m = re.exec(body)) !== null) frames.push({ wire: m[1], name: m[2] });
  return frames;
}

/** Extract a generated `export const NAME: ... = [ "a", "b" ];` array -> [string]. */
export function parseTsArrayConst(src, name) {
  const m = src.match(new RegExp(`export const ${name}[^=]*=\\s*\\[([\\s\\S]*?)\\]`));
  if (!m) throw new Error(`TS: ${name} array not found`);
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

function parseStringConst(src, regex, label) {
  const m = src.match(regex);
  if (!m) throw new Error(`${label}: not found`);
  return m[1];
}

function parseIntConst(src, regex, label) {
  const m = src.match(regex);
  if (!m) throw new Error(`${label}: not found`);
  return evalIntExpr(m[1]);
}

// ── checks ───────────────────────────────────────────────────────────────────

function setEq(a, b) {
  if (a.size !== b.size) return false;
  for (const x of a) if (!b.has(x)) return false;
  return true;
}

function diff(expected, actual) {
  const exp = new Set(expected);
  const act = new Set(actual);
  return {
    missing: [...exp].filter((x) => !act.has(x)),
    extra: [...act].filter((x) => !exp.has(x)),
  };
}

export function checkParity(proto = validateProtocol(loadProtocol())) {
  const errors = [];
  const canonWires = proto.frames.map((f) => f.wire);
  const canonById = new Map(proto.frames.map((f) => [f.id, f.wire]));
  const relayWires = proto.frames.filter((f) => f.relayAccepted).map((f) => f.wire);
  const p = proto.protocol;

  // Swift frame enum — full set, with id->wire mapping.
  try {
    const swift = parseSwiftFrames(read(PATHS.swiftEnum));
    const d = diff(canonWires, swift.map((f) => f.wire));
    if (d.missing.length || d.extra.length) {
      errors.push(`Swift frame set drift: missing ${JSON.stringify(d.missing)}, extra ${JSON.stringify(d.extra)}`);
    }
    for (const f of swift) {
      if (canonById.has(f.id) && canonById.get(f.id) !== f.wire) {
        errors.push(`Swift frame "${f.id}" maps to "${f.wire}" but canon says "${canonById.get(f.id)}"`);
      }
    }
  } catch (e) {
    errors.push(`Swift: ${e.message}`);
  }

  // Kotlin frame enum — full set; @SerialName must equal canon wire, name must be SCREAMING_SNAKE of id.
  try {
    const kotlin = parseKotlinFrames(read(PATHS.kotlinEnum));
    const d = diff(canonWires, kotlin.map((f) => f.wire));
    if (d.missing.length || d.extra.length) {
      errors.push(`Kotlin frame set drift: missing ${JSON.stringify(d.missing)}, extra ${JSON.stringify(d.extra)}`);
    }
    const wireToName = new Map(kotlin.map((f) => [f.wire, f.name]));
    for (const f of proto.frames) {
      const expectedName = f.id.replace(/([A-Z])/g, "_$1").toUpperCase();
      if (wireToName.has(f.wire) && wireToName.get(f.wire) !== expectedName) {
        errors.push(`Kotlin "${f.wire}" enum constant is "${wireToName.get(f.wire)}" but canon id implies "${expectedName}"`);
      }
    }
  } catch (e) {
    errors.push(`Kotlin: ${e.message}`);
  }

  // TS relay — must CONSUME the generated subset (never hand-roll it), and the
  // generated subset must equal canon's relayAccepted frames.
  try {
    const tsSrc = read(PATHS.tsRelay);
    const importsGenerated =
      /from\s+"\.\/generated\/wireProtocol\.js"/.test(tsSrc) && /RELAY_ACCEPTED_FRAME_TYPES/.test(tsSrc);
    if (!importsGenerated) {
      errors.push(
        "TS relay protocol.ts must import RELAY_ACCEPTED_FRAME_TYPES from ./generated/wireProtocol.js (do not hand-roll the relay frame set)",
      );
    }
    const handRolled = tsSrc.match(/new\s+Set<string>\s*\(\s*\[([\s\S]*?)\]/);
    if (handRolled && /"[a-z]+(?:\.[a-z]+)+"/.test(handRolled[1])) {
      errors.push("TS relay protocol.ts hand-rolls a frame-type Set literal; consume RELAY_ACCEPTED_FRAME_TYPES instead");
    }
    const genArr = parseTsArrayConst(read(PATHS.generatedTs), "RELAY_ACCEPTED_FRAME_TYPES");
    const d = diff(relayWires, genArr);
    if (d.missing.length || d.extra.length) {
      errors.push(
        `Generated relay subset drift vs canon relayAccepted: missing ${JSON.stringify(d.missing)}, extra ${JSON.stringify(d.extra)}`,
      );
    }
  } catch (e) {
    errors.push(`TS: ${e.message}`);
  }

  // Rust wire constants.
  try {
    const rust = read(PATHS.rust);
    const alpn = parseStringConst(rust, /OPENBURNBAR_ALPN:\s*&\[u8\]\s*=\s*b"([^"]+)"/, "Rust OPENBURNBAR_ALPN");
    const max = parseIntConst(rust, /OPENBURNBAR_MAX_FRAME_BYTES:\s*usize\s*=\s*([\d *]+);/, "Rust OPENBURNBAR_MAX_FRAME_BYTES");
    if (alpn !== p.alpn) errors.push(`Rust ALPN "${alpn}" != canon "${p.alpn}"`);
    if (max !== p.maxFrameBytes) errors.push(`Rust MAX_FRAME_BYTES ${max} != canon ${p.maxFrameBytes}`);
  } catch (e) {
    errors.push(`Rust: ${e.message}`);
  }

  // Swift iroh constants.
  try {
    const s = read(PATHS.swiftIroh);
    const alpn = parseStringConst(s, /static let alpn\s*=\s*"([^"]+)"/, "Swift iroh alpn");
    const max = parseIntConst(s, /static let maxFrameBytes:\s*Int\s*=\s*([\d *]+)/, "Swift iroh maxFrameBytes");
    const prefix = parseIntConst(s, /static let lengthPrefixBytes\s*=\s*([\d *]+)/, "Swift iroh lengthPrefixBytes");
    if (alpn !== p.alpn) errors.push(`Swift iroh alpn "${alpn}" != canon "${p.alpn}"`);
    if (max !== p.maxFrameBytes) errors.push(`Swift iroh maxFrameBytes ${max} != canon ${p.maxFrameBytes}`);
    if (prefix !== p.lengthPrefixBytes) errors.push(`Swift iroh lengthPrefixBytes ${prefix} != canon ${p.lengthPrefixBytes}`);
  } catch (e) {
    errors.push(`Swift iroh: ${e.message}`);
  }

  // Kotlin iroh constants.
  try {
    const k = read(PATHS.kotlinIroh);
    const alpn = parseStringConst(k, /const val ALPN:\s*String\s*=\s*"([^"]+)"/, "Kotlin iroh ALPN");
    const max = parseIntConst(k, /const val MAX_FRAME_BYTES:\s*Int\s*=\s*([\d *]+)/, "Kotlin iroh MAX_FRAME_BYTES");
    const prefix = parseIntConst(k, /const val LENGTH_PREFIX_BYTES:\s*Int\s*=\s*([\d *]+)/, "Kotlin iroh LENGTH_PREFIX_BYTES");
    if (alpn !== p.alpn) errors.push(`Kotlin iroh ALPN "${alpn}" != canon "${p.alpn}"`);
    if (max !== p.maxFrameBytes) errors.push(`Kotlin iroh MAX_FRAME_BYTES ${max} != canon ${p.maxFrameBytes}`);
    if (prefix !== p.lengthPrefixBytes) errors.push(`Kotlin iroh LENGTH_PREFIX_BYTES ${prefix} != canon ${p.lengthPrefixBytes}`);
  } catch (e) {
    errors.push(`Kotlin iroh: ${e.message}`);
  }

  return errors;
}

function main() {
  const errors = checkParity();
  if (errors.length) {
    console.error("FAIL: Hermes wire-protocol parity drift detected:\n  - " + errors.join("\n  - "));
    console.error("\nThe canonical source is packages/hermes-wire-protocol/protocol.json.");
    console.error("Update it and run `node codegen.mjs`, then re-sync the hand-written surfaces.");
    process.exit(1);
  }
  console.log("PASS: all Swift / Kotlin / TS / Rust wire-protocol surfaces match protocol.json.");
}

if (import.meta.url === `file://${process.argv[1]}`) main();
