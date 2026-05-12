#!/usr/bin/env node
/**
 * Capture local commercial-launch evidence without committing live proof data.
 *
 * By default this runs scripts/commercial-launch-gate.mjs and writes the JSON
 * payload plus capture metadata under ./launch-evidence/. That directory is
 * intentionally gitignored because post-release proof can include Firebase UIDs
 * and App Store transaction identifiers.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import process from "node:process";

const DEFAULT_DIR = "launch-evidence";
const DEFAULT_KIND = "commercial-launch-gate";

function usage() {
  console.log(`Usage:
  scripts/capture-commercial-launch-evidence.mjs
  scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input proof.json
  npm --prefix functions run prove:hosted-quota -- ... | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input -

Options:
  --dir <path>     Output directory. Default: ${DEFAULT_DIR}
  --input <path>   Capture JSON from a file, or "-" for stdin. Default: run the launch gate.
  --kind <name>    Evidence kind used in the filename. Default: ${DEFAULT_KIND}
  --help           Show this help.
`);
}

function parseArgs(argv) {
  const options = {
    dir: DEFAULT_DIR,
    input: null,
    kind: DEFAULT_KIND,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      options.help = true;
      continue;
    }
    if (arg === "--dir" || arg === "--input" || arg === "--kind") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`${arg} requires a value`);
      }
      options[arg.slice(2)] = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

function safeSlug(value) {
  const slug = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!slug) throw new Error("kind must contain at least one filename-safe character");
  return slug;
}

function firstJSON(text) {
  const source = String(text || "");
  const start = source.indexOf("{");
  if (start < 0) throw new Error("No JSON object found in evidence input");
  return JSON.parse(source.slice(start));
}

function readEvidenceInput(input) {
  if (input === "-") {
    return {
      source: "stdin",
      command: null,
      exitStatus: null,
      text: readFileSync(0, "utf8"),
    };
  }
  if (input) {
    return {
      source: resolve(input),
      command: null,
      exitStatus: null,
      text: readFileSync(input, "utf8"),
    };
  }

  const command = "scripts/commercial-launch-gate.mjs";
  const result = spawnSync(command, {
    cwd: process.cwd(),
    env: process.env,
    encoding: "utf8",
    shell: true,
    timeout: 180_000,
  });
  if (result.status !== 0 && !result.stdout.includes("{")) {
    const output = [result.stdout, result.stderr, result.error?.message].filter(Boolean).join("\n");
    throw new Error(`Launch gate failed with status ${result.status ?? "unknown"}:\n${output}`);
  }
  return {
    source: command,
    command,
    exitStatus: result.status,
    text: result.stdout,
  };
}

function statusSuffix(kind, payload) {
  if (kind === DEFAULT_KIND && payload?.verdict?.status) {
    return safeSlug(payload.verdict.status);
  }
  if (payload?.ok === true) return "ok";
  if (payload?.ok === false) return "not-ok";
  return "captured";
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }

  const kind = safeSlug(options.kind);
  const evidence = readEvidenceInput(options.input);
  const payload = firstJSON(evidence.text);
  const capturedAt = new Date().toISOString();
  const stamp = capturedAt.replace(/[:.]/g, "-");
  const outputDir = resolve(options.dir);
  mkdirSync(outputDir, { recursive: true });

  const record = {
    capturedAt,
    kind,
    source: evidence.source,
    sourceCommand: evidence.command,
    sourceExitStatus: evidence.exitStatus,
    workingDirectory: process.cwd(),
    payload,
  };
  const filename = `${stamp}-${kind}-${statusSuffix(kind, payload)}.json`;
  const outputPath = join(outputDir, filename);
  const latestPath = join(outputDir, `latest-${kind}.json`);
  const body = `${JSON.stringify(record, null, 2)}\n`;
  writeFileSync(outputPath, body, { flag: "wx" });
  writeFileSync(latestPath, body);

  const verdict = payload?.verdict?.status || (payload?.ok === true ? "ok" : payload?.ok === false ? "not-ok" : "captured");
  console.log(JSON.stringify({
    ok: true,
    kind,
    verdict,
    outputPath,
    latestPath,
    filename: basename(outputPath),
  }, null, 2));
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
