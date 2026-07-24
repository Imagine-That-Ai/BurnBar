#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  artifactRecord,
  atomicWriteJson,
  DIGEST_PATTERN,
  HEAD_PATTERN,
  RUN_ID_PATTERN,
  SHA256_PATTERN,
  VERSION_PATTERN,
} from "./lib/installed-ui-proof.mjs";
import {
  buildP29Proof,
  P29_PROOF_FILENAME,
  P29_PROOF_ROLE,
  validateP29InstalledSession,
  validateP29Proof,
} from "./lib/p29-text-expansion-proof.mjs";
import {
  readRegularSnapshot,
  SUPPORT_ENVIRONMENTS,
} from "./lib/product-proof-closure.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
function head(root) {
  return spawnSync("git", ["rev-parse", "HEAD"], {
    cwd: root,
    encoding: "utf8",
  }).stdout.trim();
}
function confined(root, candidate, label) {
  const realRoot = fs.realpathSync(root);
  const absolute = fs.realpathSync(candidate);
  const relative = path.relative(realRoot, absolute);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  )
    throw new Error(`${label} must remain inside the repository`);
  return { root: realRoot, absolute };
}
export function captureP29TextExpansionProof(
  options,
  { resolveHead = head, now = () => new Date() } = {},
) {
  if (
    !SUPPORT_ENVIRONMENTS.includes(options.environmentId) ||
    !HEAD_PATTERN.test(options.targetHead ?? "") ||
    !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) ||
    !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") ||
    !VERSION_PATTERN.test(options.packageVersion ?? "") ||
    !SHA256_PATTERN.test(options.manifestSha256 ?? "") ||
    !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")
  )
    throw new Error("P-29 invocation binding is invalid");
  const input = confined(
    options.repoRoot ?? ROOT,
    options.inputRoot,
    "P-29 input root",
  );
  const report = confined(
    input.root,
    options.sessionReport,
    "P-29 session report",
  );
  if (resolveHead(input.root) !== options.targetHead)
    throw new Error("P-29 target HEAD does not match checkout HEAD");
  const source = artifactRecord(
    input.root,
    report.absolute,
    "P-29",
    options.environmentId,
    "P-29 session report",
  );
  const binding = {
    ...options,
    repoRoot: input.root,
    candidateRunId: String(options.candidateRunId),
  };
  const validated = validateP29InstalledSession(
    JSON.parse(fs.readFileSync(report.absolute, "utf8")),
    binding,
    { repoRoot: input.root },
  );
  const proof = buildP29Proof({
    session: validated.document,
    source,
    collectedAt: now().toISOString(),
    operationCount: validated.operationCount,
  });
  const output = path.join(
    input.absolute,
    "feature-artifacts",
    P29_PROOF_FILENAME,
  );
  const registration = path.join(
    input.absolute,
    "feature-proof-registration.json",
  );
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWriteJson(output, proof);
  const record = artifactRecord(
    input.root,
    output,
    "P-29",
    options.environmentId,
    "P-29 proof",
  );
  validateP29Proof({
    ...binding,
    snapshot: readRegularSnapshot(input.root, record.path, "P-29 proof"),
  });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: "P-29",
    environmentId: options.environmentId,
    artifacts: [
      { role: P29_PROOF_ROLE, path: `feature-artifacts/${P29_PROOF_FILENAME}` },
    ],
  });
  return { output, registration, document: proof };
}
