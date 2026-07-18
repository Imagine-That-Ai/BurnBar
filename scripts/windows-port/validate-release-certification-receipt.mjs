#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { validateReceipt } from "./validate-release-certification-evidence.mjs";

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function main(argv) {
  if (argv.length < 1 || argv.length > 2) {
    throw new Error(
      "usage: validate-release-certification-receipt.mjs <receipt.json> [evidence-root]",
    );
  }
  const receiptPath = resolve(argv[0]);
  const evidenceRoot = resolve(argv[1] ?? dirname(receiptPath));
  if (!existsSync(receiptPath)) throw new Error(`receipt is missing: ${receiptPath}`);
  if (!existsSync(evidenceRoot)) throw new Error(`evidence root is missing: ${evidenceRoot}`);
  const receipt = JSON.parse(stripBom(readFileSync(receiptPath, "utf8")));
  const result = validateReceipt(receipt, {
    bundleDir: evidenceRoot,
    label: receiptPath,
  });
  if (!result.ok) {
    console.error("FAIL: Windows release-certification receipt is invalid.");
    for (const error of result.errors) console.error(`- ${error}`);
    process.exitCode = 1;
    return;
  }
  console.log(`PASS: Windows release-certification receipt is valid (${receipt.gate}).`);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 2;
}
