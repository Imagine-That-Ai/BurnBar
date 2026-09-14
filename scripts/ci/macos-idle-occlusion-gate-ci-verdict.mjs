#!/usr/bin/env node
// CI verdict for P-PERF-3 evidence. The real-process helper cannot show/hide
// windows on GitHub-hosted VirtualMac runners (helper-timeout). That is
// infrastructure, not a CPU-budget regression. Budget failures stay red.
import { readFileSync } from "node:fs";
import process from "node:process";
import { pathToFileURL } from "node:url";

export function ciVerdict(evidence) {
  if (!evidence || typeof evidence !== "object") {
    return { exitCode: 1, reason: "missing-evidence" };
  }
  const status = evidence.status;
  if (status === "passed" || status === "skipped") {
    return { exitCode: 0, reason: status };
  }
  const failureClass = evidence.failureClass ?? null;
  const reasonCode = evidence.reasonCode ?? null;
  const model = evidence.machineIdentity?.hardware?.model ?? "";
  const virtualMac = String(model).startsWith("VirtualMac");
  // Hosted VirtualMac cannot show the dashboard window. Only that helper-timeout
  // is a known environmental skip. launch-failed / no-backdrop-ack stay red.
  if (failureClass === "infra" && reasonCode === "helper-timeout" && virtualMac) {
    return { exitCode: 0, reason: "virtual-mac-helper-timeout" };
  }
  return { exitCode: 1, reason: reasonCode ?? failureClass ?? status ?? "failed" };
}

function main(argv = process.argv.slice(2)) {
  const path = argv[0];
  if (!path) {
    process.stderr.write("usage: macos-idle-occlusion-gate-ci-verdict.mjs <evidence.json>\n");
    process.exit(2);
  }
  const evidence = JSON.parse(readFileSync(path, "utf8"));
  const verdict = ciVerdict(evidence);
  process.stdout.write(`${verdict.reason}\n`);
  if (verdict.exitCode !== 0) {
    process.stderr.write(
      `error: P-PERF-3 CI verdict failed (${verdict.reason})\n`,
    );
  }
  process.exit(verdict.exitCode);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
