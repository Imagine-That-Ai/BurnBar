#!/usr/bin/env node

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { resolveActiveDomainCoreActivation } from "../lib/domain-core-activation.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function argument(argv, flag) {
  const index = argv.indexOf(flag);
  if (index < 0 || !argv[index + 1] || argv[index + 1].startsWith("--")) {
    throw new Error(`${flag} is required`);
  }
  if (argv.indexOf(flag, index + 1) >= 0)
    throw new Error(`${flag} cannot be repeated`);
  return argv[index + 1];
}

export function run(argv) {
  const allowed = new Set(["--release-commit", "--format", "--allow-dirty"]);
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag.startsWith("--")) {
      if (!allowed.has(flag)) throw new Error(`unknown argument: ${flag}`);
      if (flag === "--allow-dirty") continue;
      index += 1;
    }
  }
  const activation = resolveActiveDomainCoreActivation({
    repoRoot: ROOT,
    activationCommit: argument(argv, "--release-commit"),
    requireClean: !argv.includes("--allow-dirty"),
  });
  const format = argv.includes("--format")
    ? argument(argv, "--format")
    : "json";
  if (format === "json") {
    process.stdout.write(`${JSON.stringify(activation, null, 2)}\n`);
  } else if (format === "github-output") {
    process.stdout.write(
      `active=${activation.active}\ncandidate_commit=${activation.candidateCommit}\nactivation_commit=${activation.activationCommit}\nactivation_sha256=${activation.changedPathsSha256}\n`,
    );
  } else {
    throw new Error(`unsupported format: ${format}`);
  }
  return activation;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
