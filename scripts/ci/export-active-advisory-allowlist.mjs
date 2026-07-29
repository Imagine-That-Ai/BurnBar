#!/usr/bin/env node

import { appendFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  ADVISORY_ALLOWLIST,
  activeAllowlistEntry,
} from "./check-npm-audit-fail-closed.mjs";

const GHSA_PATTERN =
  /^GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}$/i;

export function parseOsvIgnoredVulnerabilities(content) {
  const entries = [];
  let current = null;

  for (const rawLine of content.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (line === "[[IgnoredVulns]]") {
      if (current) entries.push(current);
      current = {};
      continue;
    }
    if (!current || line.length === 0 || line.startsWith("#")) continue;

    const idMatch = line.match(/^id\s*=\s*"([^"]+)"$/u);
    if (idMatch) {
      current.id = idMatch[1];
      continue;
    }
    const untilMatch = line.match(/^ignoreUntil\s*=\s*(\S+)$/u);
    if (untilMatch) {
      current.ignoreUntil = untilMatch[1];
      continue;
    }
    const reasonMatch = line.match(/^reason\s*=\s*"([^"]+)"$/u);
    if (reasonMatch) current.reason = reasonMatch[1];
  }
  if (current) entries.push(current);
  return entries;
}

export function resolveActiveAdvisoryAllowlist({
  npmAllowlist = ADVISORY_ALLOWLIST,
  osvEntries,
  now = new Date(),
}) {
  const osvById = new Map();
  for (const entry of osvEntries) {
    if (
      !GHSA_PATTERN.test(entry.id ?? "") ||
      Number.isNaN(Date.parse(entry.ignoreUntil ?? "")) ||
      typeof entry.reason !== "string" ||
      entry.reason.length < 8
    ) {
      throw new Error(
        `Malformed osv-scanner.toml IgnoredVulns entry: ${JSON.stringify(entry)}`,
      );
    }
    if (osvById.has(entry.id)) {
      throw new Error(
        `Duplicate osv-scanner.toml advisory ignore: ${entry.id}`,
      );
    }
    osvById.set(entry.id, entry);
  }

  const npmIds = Object.keys(npmAllowlist).sort();
  const osvIds = [...osvById.keys()].sort();
  if (JSON.stringify(npmIds) !== JSON.stringify(osvIds)) {
    throw new Error(
      `Advisory allowlists are out of sync: npm=${npmIds.join(",") || "(empty)"} ` +
        `osv=${osvIds.join(",") || "(empty)"}`,
    );
  }

  const active = [];
  for (const id of npmIds) {
    const npmEntry = npmAllowlist[id];
    const osvEntry = osvById.get(id);
    if (npmEntry.expires !== osvEntry.ignoreUntil.slice(0, 10)) {
      throw new Error(
        `Advisory expiry mismatch for ${id}: npm=${npmEntry.expires} ` +
          `osv=${osvEntry.ignoreUntil}`,
      );
    }
    if (
      activeAllowlistEntry(id, npmAllowlist, now) &&
      now.getTime() < Date.parse(osvEntry.ignoreUntil)
    ) {
      active.push(id);
    }
  }
  return active;
}

function main() {
  const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
  const osvEntries = parseOsvIgnoredVulnerabilities(
    readFileSync(join(repoRoot, "osv-scanner.toml"), "utf8"),
  );
  const active = resolveActiveAdvisoryAllowlist({ osvEntries });
  const value = active.join(",");

  if (!process.env.GITHUB_OUTPUT) {
    throw new Error(
      "GITHUB_OUTPUT is required; refusing to emit an unaudited workflow value",
    );
  }
  appendFileSync(process.env.GITHUB_OUTPUT, `allow-ghsas=${value}\n`, "utf8");
  console.log(
    value
      ? `Active time-boxed dependency-review advisories: ${value}`
      : "No active time-boxed dependency-review advisories.",
  );
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
