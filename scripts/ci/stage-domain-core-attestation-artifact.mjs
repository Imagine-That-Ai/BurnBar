#!/usr/bin/env node

import { cpSync, existsSync, lstatSync, mkdirSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

function args(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--artifact", "--identity-report", "--output"].includes(flag))
      throw new Error(`unknown argument: ${flag}`);
    if (!value || value.startsWith("--") || values.has(flag))
      throw new Error(`${flag} requires one value`);
    values.set(flag, value);
  }
  for (const flag of ["--artifact", "--identity-report", "--output"]) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

export function stage({ artifactPath, identityReportPath, outputPath }) {
  const artifact = resolve(artifactPath);
  const report = resolve(identityReportPath);
  const output = resolve(outputPath);
  if (!existsSync(artifact)) throw new Error("artifact path does not exist");
  const artifactStat = lstatSync(artifact);
  if (
    artifactStat.isSymbolicLink() ||
    (!artifactStat.isFile() && !artifactStat.isDirectory())
  ) {
    throw new Error(
      "artifact path must be a regular file or directory, not a symlink",
    );
  }
  if (!existsSync(report))
    throw new Error(
      "observed identity report must be a non-empty regular file",
    );
  const reportStat = lstatSync(report);
  if (
    reportStat.isSymbolicLink() ||
    !reportStat.isFile() ||
    reportStat.size === 0
  ) {
    throw new Error("observed identity report must be a non-empty file");
  }
  rmSync(output, { recursive: true, force: true });
  mkdirSync(output, { recursive: true });
  cpSync(artifact, resolve(output, "artifact"), {
    recursive: true,
    errorOnExist: true,
  });
  cpSync(report, resolve(output, "observed-identity.json"), {
    errorOnExist: true,
  });
}

export function run(argv) {
  const values = args(argv);
  stage({
    artifactPath: values.get("--artifact"),
    identityReportPath: values.get("--identity-report"),
    outputPath: values.get("--output"),
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
