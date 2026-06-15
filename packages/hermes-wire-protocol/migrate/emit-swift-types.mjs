#!/usr/bin/env node
/**
 * Swift emitter for the rich Hermes relay payload types.
 *
 * Consumes the declarative type model (see roundtrip.mjs / protocol.json types[])
 * and emits the data + Codable SKELETON for each type — exactly the bytes the
 * hand-written HermesRealtimeRelayTypes.swift carries today, minus behavior
 * (computed properties / statics / methods), which live in a hand-written
 * +Behavior.swift extension. Order of CodingKeys == field order (wire bytes
 * follow declaration order; the relay frame codec uses .withoutEscapingSlashes,
 * NOT .sortedKeys, so order is load-bearing).
 *
 * The three date regimes are first-class and PER-FIELD (never a global knob):
 *   iso                    decode + encode via HermesRealtimeRelayDateCodec
 *   numeric                synthesized Codable (JSON number both ways)
 *   numericEncodeIsoDecode DateCodec.decode in, raw numeric encode out
 */

export const DATE_CODEC_NAME = "HermesRealtimeRelayDateCodec";

const I1 = "    ";
const I2 = "        ";

function emitTrivia(trivia, indent = "") {
  // trivia is an array of raw source lines (doc comments / blank). Re-emit verbatim.
  return (trivia || []).map((l) => l).join("\n");
}

function withTrivia(trivia, body, indent = "") {
  const t = (trivia || []).filter((l) => l.trim() !== "");
  if (!t.length) return body;
  return t.join("\n") + "\n" + body;
}

function emitEnum(t, indent = "") {
  const lines = [];
  const conf = t.conformances.join(", ");
  lines.push(`${indent}public enum ${t.name}: ${conf} {`);
  for (const c of t.cases) {
    for (const tl of (c.trivia || []).filter((l) => l.trim() !== "")) lines.push(tl);
    if (c.implicit) lines.push(`${indent}${I1}case ${c.id}`);
    else lines.push(`${indent}${I1}case ${c.id} = "${c.wire}"`);
  }
  lines.push(`${indent}}`);
  return lines.join("\n");
}

function emitStoredProps(t) {
  const out = [];
  for (const f of t.fields) {
    for (const tl of (f.trivia || []).filter((l) => l.trim() !== "")) out.push(tl);
    out.push(`${I1}public var ${f.name}: ${f.swiftType}`);
  }
  return out.join("\n");
}

function emitMemberwiseInit(t) {
  const params = t.fields.map((f) => {
    const def = t.initDefaults && t.initDefaults[f.name] !== undefined ? ` = ${t.initDefaults[f.name]}` : "";
    return `${I2}${f.name}: ${f.swiftType}${def}`;
  });
  const out = [];
  out.push(`${I1}public init(`);
  out.push(params.join(",\n"));
  out.push(`${I1}) {`);
  for (const f of t.fields) out.push(`${I2}self.${f.name} = ${f.name}`);
  out.push(`${I1}}`);
  return out.join("\n");
}

function emitCodingKeys(t) {
  const out = [`${I1}private enum CodingKeys: String, CodingKey {`];
  for (const [field, wire] of t.codingKeysOrdered) {
    if (wire === field) out.push(`${I2}case ${field}`);
    else out.push(`${I2}case ${field} = "${wire}"`);
  }
  out.push(`${I1}}`);
  return out.join("\n");
}

function baseType(swiftType) {
  return swiftType.replace(/\?$/, "");
}

const I3 = "            ";

function emitDecode(t) {
  const out = [`${I1}public init(from decoder: Decoder) throws {`,
              `${I2}let container = try decoder.container(keyedBy: CodingKeys.self)`];
  for (const f of t.fields) {
    const d = f.codable.decode;
    const key = f.codable.key;
    const ty = baseType(f.swiftType);
    if (d.mode === "plain") out.push(`${I2}self.${f.name} = try container.decode(${d.type || ty}.self, forKey: .${key})`);
    else if (d.mode === "ifPresent") out.push(`${I2}self.${f.name} = try container.decodeIfPresent(${d.type || ty}.self, forKey: .${key})`);
    else if (d.mode === "ifPresentDefault") out.push(`${I2}self.${f.name} = try container.decodeIfPresent(${d.type || ty}.self, forKey: .${key}) ?? ${d.default}`);
    else if (d.mode === "dateIso") out.push(`${I2}self.${f.name} = try ${DATE_CODEC_NAME}.decode(container, forKey: .${key})`);
    else if (d.mode === "dateIsoContainsGuard") out.push(
      `${I2}if container.contains(.${d.key}) {`,
      `${I3}self.${f.name} = try ${DATE_CODEC_NAME}.decode(container, forKey: .${d.key})`,
      `${I2}} else {`,
      `${I3}self.${f.name} = nil`,
      `${I2}}`);
    else if (d.mode === "dualKey") {
      d.tempNames.forEach((tmp, k) => out.push(`${I2}let ${tmp} = try container.decodeIfPresent(${ty}.self, forKey: .${d.keys[k]})`));
      out.push(`${I2}self.${f.name} = ${d.tempNames.join(" ?? ")} ?? ${d.fallback}`);
    }
    else throw new Error(`${t.name}.${f.name}: unhandled decode mode ${d.mode}`);
  }
  out.push(`${I1}}`);
  return out.join("\n");
}

function emitEncode(t) {
  const out = [`${I1}public func encode(to encoder: Encoder) throws {`,
              `${I2}var container = encoder.container(keyedBy: CodingKeys.self)`];
  for (const f of t.fields) {
    const e = f.codable.encode;
    if (!e) continue;
    const key = e.key;
    if (e.mode === "plain") out.push(`${I2}try container.encode(${f.name}, forKey: .${key})`);
    else if (e.mode === "ifPresent") out.push(`${I2}try container.encodeIfPresent(${f.name}, forKey: .${key})`);
    else if (e.mode === "dateIso") out.push(`${I2}try container.encode(${DATE_CODEC_NAME}.encode(${f.name}), forKey: .${key})`);
    else if (e.mode === "dateIsoIfLet") out.push(
      `${I2}if let ${f.name} {`,
      `${I3}try container.encode(${DATE_CODEC_NAME}.encode(${f.name}), forKey: .${key})`,
      `${I2}}`);
    else if (e.mode === "dualKey") e.keys.forEach((kk) => out.push(`${I2}try container.encode(${f.name}, forKey: .${kk})`));
    else throw new Error(`${t.name}.${f.name}: unhandled encode mode ${e.mode}`);
  }
  out.push(`${I1}}`);
  return out.join("\n");
}

/**
 * Emit one type's data+Codable skeleton.
 * opts.behaviorInPlace: array of {after, lines} to splice verbatim (round-trip mode).
 */
export function emitSwiftType(t) {
  if (t.kind === "enum") return emitEnum(t);
  const out = [];
  const conf = t.conformances.join(", ");
  out.push(`public struct ${t.name}: ${conf} {`);
  out.push(emitStoredProps(t));
  for (const n of t.nested || []) out.push(emitEnum(n.model, I1));
  out.push(emitMemberwiseInit(t));
  if (t.hasCustomCodable) {
    if (t.codingKeysOrdered) out.push(emitCodingKeys(t));
    if (t.decode) out.push(emitDecode(t));
    if (t.encode) out.push(emitEncode(t));
  }
  out.push("}");
  return out.join("\n");
}

export function emitDateCodecHelper(rawLines) {
  // Emitted verbatim from the captured source (exact two-formatter fallback + message).
  return rawLines.join("\n");
}
