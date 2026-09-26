import { readFileSync } from "node:fs";

/**
 * Parse a flat string enum from a domain .tsp (`name: "value",` members with
 * optional `///` docs). Unlike model domains — whose emit templates are
 * hand-mirrored and ratcheted by check-tsp-canon — the RPC catalog derives
 * straight from the canon, so a method addition is a TypeSpec edit with no
 * template to keep in lockstep. The parse is strict: anything unexpected
 * inside the enum block fails the emit loudly.
 *
 * Shared by emit/generate.mjs and tools/ipc/generate-burnbarrpc-canon.mjs so
 * the language emits and the IPC canon cannot parse the catalog differently.
 */
export function parseTspStringEnum(tspPath, enumName) {
  const source = readFileSync(tspPath, "utf8");
  const start = source.indexOf(`enum ${enumName} {`);
  if (start < 0) throw new Error(`enum ${enumName} not found in ${tspPath}`);
  const open = source.indexOf("{", start);
  const close = source.indexOf("\n}", open);
  if (close < 0) throw new Error(`enum ${enumName} block unterminated in ${tspPath}`);
  const members = [];
  let docs = [];
  for (const line of source.slice(open + 1, close).split("\n")) {
    const doc = line.match(/^\s*\/\/\/\s?(.*)$/);
    if (doc) {
      docs.push(doc[1]);
      continue;
    }
    if (line.trim() === "") {
      docs = [];
      continue;
    }
    const member = line.match(/^\s*([A-Za-z0-9_]+)\s*:\s*"([^"]+)"\s*,?\s*$/);
    if (!member) throw new Error(`unparsed ${enumName} member line: ${line.trim()}`);
    members.push({ name: member[1], value: member[2], docs });
    docs = [];
  }
  if (members.length === 0) throw new Error(`enum ${enumName} has no members in ${tspPath}`);
  const names = new Set();
  const values = new Set();
  for (const member of members) {
    if (names.has(member.name)) throw new Error(`duplicate ${enumName} member ${member.name}`);
    if (values.has(member.value)) throw new Error(`duplicate ${enumName} value ${member.value}`);
    names.add(member.name);
    values.add(member.value);
  }
  return members;
}
