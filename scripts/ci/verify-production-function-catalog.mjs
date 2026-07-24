#!/usr/bin/env node

/**
 * Fail-closed post-deploy check for parity-critical callable exports.
 *
 * Firebase's JSON envelope has changed shape across CLI releases, so this
 * accepts both the current `{ result: [...] }` form and a raw array while
 * requiring exact callable ids for the Linux App Check enrollment surface.
 */

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const REQUIRED_LINUX_APPCHECK_CALLABLES = Object.freeze([
  "issueLinuxAppCheckChallenge",
  "registerLinuxAppCheckDevice",
  "approveLinuxAppCheckDevice",
  "listLinuxAppCheckDevices",
  "revokeLinuxAppCheckDevice",
  "mintLinuxAppCheckToken",
]);

function parseArgs(argv) {
  const index = argv.indexOf("--input");
  if (index === -1) return { inputPath: undefined };
  const inputPath = argv[index + 1];
  if (!inputPath || inputPath.startsWith("--")) {
    throw new Error("--input requires a JSON file path");
  }
  return { inputPath };
}

export function extractFunctionNames(payload) {
  const records = Array.isArray(payload) ? payload : payload?.result;
  if (!Array.isArray(records)) {
    throw new Error("Firebase functions:list JSON must contain a result array");
  }

  const names = new Set();
  for (const record of records) {
    if (typeof record === "string") {
      names.add(record);
      continue;
    }
    if (!record || typeof record !== "object") continue;
    for (const key of ["id", "name", "function", "exportedName"]) {
      const value = record[key];
      if (typeof value === "string" && value.length > 0) {
        names.add(value.split("/").at(-1));
      }
    }
  }
  return names;
}

export function verifyRequiredFunctions(payload, required = REQUIRED_LINUX_APPCHECK_CALLABLES) {
  const names = extractFunctionNames(payload);
  const missing = required.filter((name) => !names.has(name));
  return {
    required: [...required],
    discovered: [...names].sort(),
    missing,
    passed: missing.length === 0,
  };
}

async function readInput(inputPath) {
  const raw = inputPath
    ? await readFile(inputPath, "utf8")
    : await new Promise((resolve, reject) => {
        let value = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", (chunk) => (value += chunk));
        process.stdin.on("end", () => resolve(value));
        process.stdin.on("error", reject);
      });
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Unable to parse Firebase functions:list JSON: ${error.message}`);
  }
}

async function main() {
  const { inputPath } = parseArgs(process.argv.slice(2));
  const result = verifyRequiredFunctions(await readInput(inputPath));
  if (!result.passed) {
    console.error(`FAIL: production is missing required Linux callables: ${result.missing.join(", ")}`);
    console.error(JSON.stringify(result));
    process.exitCode = 1;
    return;
  }
  console.log(`PASS: production exposes ${result.required.length} required Linux callables.`);
  console.log(JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}
