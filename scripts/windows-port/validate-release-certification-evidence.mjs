#!/usr/bin/env node
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const BUNDLE_SCHEMA = "openburnbar.windows.release-certification-bundle.v1";
export const RECEIPT_SCHEMA = "openburnbar.windows.release-certification-receipt.v1";
export const CHECKSUM_FILE = "SHA256SUMS";
export const REQUIRED_GATE_IDS = [
  "local-automated-checks",
  "physical-performance-x64",
  "physical-performance-arm64",
  "accessibility-display",
  "staging-cloud",
  "media-computer-use-safety",
  "store-update-lifecycle",
];

const STATUSES = new Set(["PASS", "FAIL", "BLOCKED", "NOT_RUN"]);
const PHYSICAL_GATES = new Set(REQUIRED_GATE_IDS.slice(1));
const PHYSICAL_PERFORMANCE_ARCHITECTURES = new Map([
  ["physical-performance-x64", "x64"],
  ["physical-performance-arm64", "arm64"],
]);
const PHYSICAL_ASSET_TAG_SOURCES = new Set([
  "Win32_SystemEnclosure.SMBIOSAssetTag",
  "Win32_ComputerSystemProduct.IdentifyingNumber",
]);
const VIRTUAL_HOST_IDENTITY_PATTERN =
  /(VMware|VirtualBox|QEMU|UTM|Parallels|KVM|Virtual Machine|Hyper-V|Amazon EC2|Google Compute Engine|HVM domU|\bXen\b|OpenStack|Bochs|BHYVE|DigitalOcean)/i;
const REQUIRED_RECEIPT_FIELDS = [
  "schema",
  "status",
  "gate",
  "target",
  "source",
  "artifact",
  "device",
  "protocol",
  "time",
  "expected",
  "observed",
  "exitCode",
  "evidence",
  "blocker",
];

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeArchitecture(value) {
  const normalized = String(value ?? "")
    .toLowerCase()
    .replaceAll(/[^a-z0-9]/g, "");
  if (["arm64", "aarch64"].includes(normalized)) return "arm64";
  if (["x64", "amd64", "x8664"].includes(normalized)) return "x64";
  return normalized;
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readJson(path, errors, label) {
  try {
    return JSON.parse(stripBom(readFileSync(path, "utf8")));
  } catch (error) {
    errors.push(`${label}: invalid JSON: ${error.message}`);
    return null;
  }
}

function isInside(root, path) {
  const rootPath = resolve(root);
  const filePath = resolve(path);
  return filePath === rootPath || filePath.startsWith(`${rootPath}${sep}`);
}

function evidencePath(bundleDir, value) {
  if (!isRecord(value) || typeof value.path !== "string" || value.path.length === 0) {
    return null;
  }
  const path = resolve(bundleDir, value.path);
  return isInside(bundleDir, path) ? path : null;
}

function checkEvidenceFiles(receipt, bundleDir, errors, label) {
  const files = asArray(receipt.evidence?.files);
  if (files.length === 0) {
    errors.push(`${label}: evidence.files must contain at least one hashed file`);
    return;
  }

  for (const [index, file] of files.entries()) {
    const fileLabel = `${label}: evidence.files[${index}]`;
    const path = evidencePath(bundleDir, file);
    if (!path) {
      errors.push(`${fileLabel}: path must stay inside the bundle`);
      continue;
    }
    if (!existsSync(path) || !lstatSync(path).isFile()) {
      errors.push(`${fileLabel}: missing file ${file.path}`);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(file.sha256 ?? "")) {
      errors.push(`${fileLabel}: sha256 must be a lowercase SHA-256`);
    } else if (sha256(path) !== file.sha256) {
      errors.push(`${fileLabel}: sha256 mismatch for ${file.path}`);
    }
  }
}

function checkArtifact(receipt, errors, label) {
  const artifact = receipt.artifact;
  if (!isRecord(artifact)) {
    errors.push(`${label}: artifact is required`);
    return;
  }
  for (const field of ["name", "architecture", "availability", "sha256", "workflowRunId", "workflowRunUrl"]) {
    if (!(field in artifact) || (typeof artifact[field] !== "string" && artifact[field] !== null)) {
      errors.push(`${label}: artifact.${field} is required`);
    }
  }
  if (!["recorded", "not-applicable", "not-available"].includes(artifact.availability)) {
    errors.push(`${label}: artifact.availability is invalid`);
  }
  if (artifact.availability === "recorded") {
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? "")) {
      errors.push(`${label}: recorded artifact requires sha256`);
    }
    if (artifact.workflowRunId === null || artifact.workflowRunId === undefined) {
      errors.push(`${label}: recorded artifact requires workflowRunId`);
    }
    if (typeof artifact.workflowRunUrl !== "string" || !/^https:\/\//.test(artifact.workflowRunUrl)) {
      errors.push(`${label}: recorded artifact requires workflowRunUrl`);
    }
  }
  if (!isRecord(artifact.signature)) {
    errors.push(`${label}: artifact.signature is required`);
  } else {
    if (typeof artifact.signature.result !== "string") {
      errors.push(`${label}: artifact.signature.result is required`);
    }
    if (typeof artifact.signature.identity !== "string") {
      errors.push(`${label}: artifact.signature.identity is required`);
    }
    if (receipt.status === "PASS" && artifact.availability === "recorded" && artifact.signature.result !== "verified") {
      errors.push(`${label}: a PASS receipt requires verified artifact signature`);
    }
  }
}

function checkDevice(receipt, errors, label) {
  if (!isRecord(receipt.device)) {
    errors.push(`${label}: device is required`);
    return;
  }
  for (const field of ["kind", "manufacturer", "model", "architecture", "osBuild", "tpm"]) {
    if (typeof receipt.device[field] !== "string" || receipt.device[field].length === 0) {
      errors.push(`${label}: device.${field} is required`);
    }
  }
  if (PHYSICAL_GATES.has(receipt.gate) && receipt.status === "PASS" && receipt.device.kind !== "physical-windows") {
    errors.push(`${label}: physical gate cannot PASS on ${receipt.device.kind}`);
  }
  if (PHYSICAL_GATES.has(receipt.gate) && receipt.status === "PASS") {
    for (const field of ["assetTag", "assetTagSource"]) {
      if (typeof receipt.device[field] !== "string" || receipt.device[field].trim().length === 0) {
        errors.push(`${label}: physical PASS requires device.${field}`);
      }
    }
    if (
      typeof receipt.device.assetTagSource === "string" &&
      receipt.device.assetTagSource.trim().length > 0 &&
      !PHYSICAL_ASSET_TAG_SOURCES.has(receipt.device.assetTagSource.trim())
    ) {
      errors.push(`${label}: physical PASS has unsupported device.assetTagSource`);
    }
    const hostIdentity = `${receipt.device.manufacturer ?? ""} ${receipt.device.model ?? ""}`.trim();
    if (VIRTUAL_HOST_IDENTITY_PATTERN.test(hostIdentity)) {
      errors.push(`${label}: physical PASS device identity looks virtualized`);
    }
  }
}

function checkBlocker(receipt, errors, label) {
  if (receipt.status === "BLOCKED" || receipt.status === "NOT_RUN") {
    if (!isRecord(receipt.blocker)) {
      errors.push(`${label}: ${receipt.status} receipt requires a named blocker`);
      return;
    }
    for (const field of ["id", "owner", "missing", "recovery"]) {
      if (typeof receipt.blocker[field] !== "string" || receipt.blocker[field].length === 0) {
        errors.push(`${label}: blocker.${field} is required`);
      }
    }
  } else if (receipt.blocker !== null) {
    errors.push(`${label}: PASS/FAIL receipt must set blocker to null`);
  }
}

export function validateReceipt(receipt, options = {}) {
  const errors = [];
  const label = options.label ?? "receipt";
  const bundleDir = options.bundleDir ?? process.cwd();

  if (!isRecord(receipt)) {
    return { ok: false, errors: [`${label}: receipt must be an object`] };
  }
  for (const field of REQUIRED_RECEIPT_FIELDS) {
    if (!(field in receipt)) errors.push(`${label}: missing ${field}`);
  }
  if (receipt.schema !== RECEIPT_SCHEMA) errors.push(`${label}: schema mismatch`);
  if (!STATUSES.has(receipt.status)) errors.push(`${label}: invalid status`);
  if (typeof receipt.gate !== "string" || receipt.gate.length === 0) errors.push(`${label}: gate is required`);
  if (typeof receipt.target !== "string" || receipt.target.length === 0) errors.push(`${label}: target is required`);

  if (!isRecord(receipt.source)) {
    errors.push(`${label}: source is required`);
  } else {
    if (!/^[a-f0-9]{40,64}$/.test(receipt.source.commitSha ?? "")) errors.push(`${label}: source.commitSha is invalid`);
    if (typeof receipt.source.dirtyTree !== "boolean") errors.push(`${label}: source.dirtyTree is required`);
  }

  checkArtifact(receipt, errors, label);
  checkDevice(receipt, errors, label);

  if (!isRecord(receipt.protocol)) {
    errors.push(`${label}: protocol is required`);
  } else if (asArray(receipt.protocol.commands).length === 0 && asArray(receipt.protocol.manualSteps).length === 0) {
    errors.push(`${label}: protocol requires a command or manualSteps`);
  }

  if (!isRecord(receipt.time)) {
    errors.push(`${label}: time is required`);
  } else {
    const started = Date.parse(receipt.time.startedAtUtc ?? "");
    const ended = Date.parse(receipt.time.endedAtUtc ?? "");
    if (!Number.isFinite(started) || !Number.isFinite(ended) || ended < started) {
      errors.push(`${label}: time interval is invalid`);
    }
    if (typeof receipt.time.durationSeconds !== "number" || receipt.time.durationSeconds < 0) {
      errors.push(`${label}: time.durationSeconds is invalid`);
    }
  }

  for (const field of ["expected", "observed"]) {
    if (typeof receipt[field] !== "string" || receipt[field].length === 0) errors.push(`${label}: ${field} is required`);
  }
  if (!Number.isInteger(receipt.exitCode) && receipt.exitCode !== null) errors.push(`${label}: exitCode must be an integer or null`);
  checkEvidenceFiles(receipt, bundleDir, errors, label);
  checkBlocker(receipt, errors, label);

  if (PHYSICAL_GATES.has(receipt.gate) && receipt.status === "PASS") {
    if (receipt.artifact?.availability !== "recorded") errors.push(`${label}: physical PASS requires a recorded artifact`);
    if (receipt.source?.dirtyTree === true) errors.push(`${label}: physical PASS cannot use a dirty source tree`);
    const expectedArchitecture = PHYSICAL_PERFORMANCE_ARCHITECTURES.get(receipt.gate);
    if (expectedArchitecture && normalizeArchitecture(receipt.device?.architecture) !== expectedArchitecture) {
      errors.push(`${label}: ${receipt.gate} requires ${expectedArchitecture} device architecture`);
    }
    if (expectedArchitecture && normalizeArchitecture(receipt.artifact?.architecture) !== expectedArchitecture) {
      errors.push(`${label}: ${receipt.gate} requires ${expectedArchitecture} artifact architecture`);
    }
  }

  return { ok: errors.length === 0, errors };
}

function walkFiles(root) {
  const output = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) output.push(...walkFiles(path));
    else if (entry.isFile()) output.push(path);
  }
  return output;
}

export function writeSha256Sums(bundleDir) {
  const root = resolve(bundleDir);
  const files = walkFiles(root)
    .filter((path) => relative(root, path).replaceAll("\\", "/") !== CHECKSUM_FILE)
    .sort((a, b) => a.localeCompare(b));
  const body = files
    .map((path) => `${sha256(path)}  ${relative(root, path).replaceAll("\\", "/")}`)
    .join("\n");
  writeFileSync(join(root, CHECKSUM_FILE), `${body}\n`);
}

function validateSha256Sums(bundleDir, errors) {
  const sumsPath = join(bundleDir, CHECKSUM_FILE);
  if (!existsSync(sumsPath)) {
    errors.push(`bundle: ${CHECKSUM_FILE} is missing`);
    return;
  }
  const listed = new Set();
  for (const [index, line] of readFileSync(sumsPath, "utf8").split(/\r?\n/).filter(Boolean).entries()) {
    const match = line.match(/^([a-f0-9]{64})  (.+)$/);
    if (!match) {
      errors.push(`bundle: invalid ${CHECKSUM_FILE} line ${index + 1}`);
      continue;
    }
    const path = resolve(bundleDir, match[2]);
    if (!isInside(bundleDir, path) || match[2] === CHECKSUM_FILE) {
      errors.push(`bundle: invalid checksum path ${match[2]}`);
      continue;
    }
    listed.add(relative(bundleDir, path).replaceAll("\\", "/"));
    if (!existsSync(path) || !lstatSync(path).isFile()) errors.push(`bundle: checksum file missing ${match[2]}`);
    else if (sha256(path) !== match[1]) errors.push(`bundle: checksum mismatch ${match[2]}`);
  }
  for (const path of walkFiles(bundleDir)) {
    const name = relative(bundleDir, path).replaceAll("\\", "/");
    if (name !== CHECKSUM_FILE && !listed.has(name)) errors.push(`bundle: ${name} is not in ${CHECKSUM_FILE}`);
  }
}

export function validateReleaseCertificationBundle(bundleDir, options = {}) {
  const root = resolve(bundleDir);
  const errors = [];
  const manifestPath = join(root, "certification-manifest.json");
  if (!existsSync(manifestPath)) return { ok: false, errors: ["bundle: certification-manifest.json is missing"] };
  const manifest = readJson(manifestPath, errors, "certification-manifest.json");
  if (!manifest) return { ok: false, errors };
  if (manifest.schema !== BUNDLE_SCHEMA) errors.push("bundle: schema mismatch");
  if (!/^[a-f0-9]{40,64}$/.test(manifest.source?.commitSha ?? "")) errors.push("bundle: source.commitSha is invalid");
  if (typeof manifest.source?.dirtyTree !== "boolean") errors.push("bundle: source.dirtyTree is required");
  if (!["GO", "CONDITIONAL GO", "NO-GO"].includes(manifest.overallVerdict)) errors.push("bundle: overallVerdict is invalid");

  const receiptEntries = asArray(manifest.receipts);
  if (receiptEntries.length === 0) errors.push("bundle: receipts must not be empty");
  const receiptPaths = new Set();
  const receiptByPath = new Map();
  for (const [index, entry] of receiptEntries.entries()) {
    const label = `receipt[${index}]`;
    if (!isRecord(entry) || typeof entry.path !== "string") {
      errors.push(`${label}: path is required`);
      continue;
    }
    receiptPaths.add(entry.path);
    const path = resolve(root, entry.path);
    if (!isInside(root, path) || !existsSync(path)) {
      errors.push(`${label}: receipt path is missing or outside bundle`);
      continue;
    }
    const receipt = readJson(path, errors, entry.path);
    if (!receipt) continue;
    const result = validateReceipt(receipt, { bundleDir: root, label: entry.path });
    errors.push(...result.errors);
    receiptByPath.set(entry.path, receipt);
    if (receipt.source?.commitSha !== manifest.source?.commitSha) {
      errors.push(`${label}: receipt commit does not match bundle source commit`);
    }
    if (!/^[a-f0-9]{64}$/.test(entry.sha256 ?? "")) {
      errors.push(`${label}: receipt sha256 is required`);
    } else if (entry.sha256 !== sha256(path)) {
      errors.push(`${label}: receipt sha256 mismatch`);
    }
  }

  const gates = asArray(manifest.gates);
  const gateById = new Map();
  for (const gate of gates) {
    if (!isRecord(gate) || typeof gate.id !== "string" || !STATUSES.has(gate.status)) {
      errors.push("bundle: invalid gate entry");
      continue;
    }
    if (gateById.has(gate.id)) errors.push(`bundle: duplicate gate ${gate.id}`);
    gateById.set(gate.id, gate);
    const listed = asArray(gate.receipts);
    if (listed.length === 0) errors.push(`bundle: gate ${gate.id} has no receipts`);
    for (const path of listed) {
      if (!receiptPaths.has(path)) {
        errors.push(`bundle: gate ${gate.id} references unlisted receipt ${path}`);
      } else if (receiptByPath.get(path)?.gate !== gate.id) {
        errors.push(`bundle: gate ${gate.id} does not match receipt gate in ${path}`);
      } else if (receiptByPath.get(path)?.status !== gate.status) {
        errors.push(`bundle: gate ${gate.id} status does not match ${path}`);
      }
    }
  }
  if (options.requireAllGates !== false) {
    for (const id of REQUIRED_GATE_IDS) {
      if (!gateById.has(id)) errors.push(`bundle: required gate is missing: ${id}`);
    }
  }
  if (manifest.overallVerdict === "GO") {
    const missingRequiredGate = REQUIRED_GATE_IDS.some(
      (id) => !gateById.has(id),
    );
    const nonPassingGate = [...gateById.values()].some(
      (gate) => gate.status !== "PASS",
    );
    if (missingRequiredGate || nonPassingGate) {
      errors.push(
        "bundle: overallVerdict GO requires every required gate to be present and PASS",
      );
    }
    if (manifest.source?.dirtyTree === true) {
      errors.push("bundle: overallVerdict GO requires a clean source tree");
    }
    const dirtyPassingReceipt = [...receiptByPath.values()].some(
      (receipt) => receipt.status === "PASS" && receipt.source?.dirtyTree === true,
    );
    if (dirtyPassingReceipt) {
      errors.push("bundle: overallVerdict GO cannot rely on a dirty PASS receipt");
    }
  }

  if (options.expectedCommit && manifest.source.commitSha !== options.expectedCommit) {
    errors.push(`bundle: commit mismatch expected ${options.expectedCommit} actual ${manifest.source.commitSha}`);
  }
  validateSha256Sums(root, errors);
  return { ok: errors.length === 0, errors, manifest };
}

function parseArgs(argv) {
  const args = { bundleDir: "", writeSums: false, expectedCommit: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--write-sums") args.writeSums = true;
    else if (value === "--expected-commit") args.expectedCommit = argv[++index] ?? "";
    else if (!args.bundleDir) args.bundleDir = value;
    else throw new Error(`unknown argument: ${value}`);
  }
  if (!args.bundleDir) throw new Error("bundle directory is required");
  return args;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const bundleDir = resolve(args.bundleDir);
    if (args.writeSums) {
      mkdirSync(bundleDir, { recursive: true });
      writeSha256Sums(bundleDir);
    }
    const result = validateReleaseCertificationBundle(bundleDir, { expectedCommit: args.expectedCommit || undefined });
    if (!result.ok) {
      console.error("FAIL: Windows release-certification evidence bundle is invalid.");
      for (const error of result.errors) console.error(`- ${error}`);
      process.exit(1);
    }
    console.log(`PASS: Windows release-certification evidence bundle is valid (${result.manifest.receipts.length} receipts).`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(2);
  }
}
