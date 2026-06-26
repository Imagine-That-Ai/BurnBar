#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const URI_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:/u;
const LINK_RE = /\[([^\]]+)\]\(([^)]+)\)/gu;

export function sanitizeForLog(value) {
  return String(value)
    .replace(/%/gu, "%25")
    .replace(/\r/gu, "\\r")
    .replace(/\n/gu, "\\n")
    .replace(/::/gu, ":\\:");
}

export function internalLinks(markdown) {
  return [...markdown.matchAll(LINK_RE)]
    .map((match) => ({ label: match[1], rawPath: match[2] }))
    .filter(({ rawPath }) => !URI_RE.test(rawPath))
    .map(({ label, rawPath }) => ({
      label,
      rawPath,
      path: rawPath.split("#", 1)[0],
    }))
    .filter(({ path }) => path.length > 0);
}

export function validateAgentsLinks(markdown, exists = existsSync) {
  const broken = [];
  const ok = [];
  for (const link of internalLinks(markdown)) {
    if (exists(link.path)) {
      ok.push(link);
    } else {
      broken.push(link);
    }
  }
  return { ok, broken };
}

function main() {
  const agentsPath = process.argv[2] ?? "AGENTS.md";
  const text = readFileSync(agentsPath, "utf8");
  const result = validateAgentsLinks(text);
  for (const link of result.ok) {
    console.log(`OK: ${sanitizeForLog(link.path)}`);
  }
  for (const link of result.broken) {
    console.log(`FAIL: Broken link target: '${sanitizeForLog(link.path)}'`);
  }
  if (result.broken.length > 0) {
    console.log(`::warning::${result.broken.length} broken internal link(s) found in AGENTS.md.`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

