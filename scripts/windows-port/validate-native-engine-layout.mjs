#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const REQUIRED_RESOURCE_BUNDLES = [
  "OpenBurnBarCore_OpenBurnBarCore.resources",
  "OpenBurnBarCore_OpenBurnBarKernel.resources",
];
const REQUIRED_ENGINE = "OpenBurnBarCoreCAbi.dll";

function snapshotFile(path) {
  try {
    const data = readFileSync(path);
    return {
      sha256: createHash("sha256").update(data).digest("hex"),
      sizeBytes: data.byteLength,
    };
  } catch {
    return null;
  }
}

function isInside(root, path) {
  const rootPath = resolve(root);
  const filePath = resolve(path);
  return filePath === rootPath || filePath.startsWith(`${rootPath}${sep}`);
}

function normalizedRelativePath(value) {
  if (typeof value !== "string" || value.length === 0 || isAbsolute(value)) return null;
  const normalized = value.replaceAll("\\", "/");
  if (normalized.split("/").some((part) => part === ".." || part.length === 0)) return null;
  return normalized;
}

export function validateNativeEngineLayout(layoutDirectory) {
  const root = resolve(layoutDirectory);
  const errors = [];
  const manifestPath = join(root, "native-engine-manifest.json");
  let manifestText;
  try {
    manifestText = readFileSync(manifestPath, "utf8");
  } catch {
    return { ok: false, errors: ["native-engine-manifest.json is missing"] };
  }

  let manifest;
  try {
    manifest = JSON.parse(manifestText);
  } catch (error) {
    return { ok: false, errors: [`native-engine-manifest.json is invalid JSON: ${error.message}`] };
  }

  if (manifest.schemaVersion !== 1) errors.push("manifest schemaVersion must be 1");
  if (manifest.engine !== REQUIRED_ENGINE) errors.push(`manifest engine must be ${REQUIRED_ENGINE}`);
  if (!Array.isArray(manifest.files) || manifest.files.length === 0) {
    errors.push("manifest files must be a non-empty array");
    return { ok: false, errors };
  }

  const seen = new Set();
  let engineEntry = false;
  const resourceEntries = new Set();
  for (const [index, entry] of manifest.files.entries()) {
    const label = `manifest files[${index}]`;
    const pathValue = normalizedRelativePath(entry?.fileName);
    if (!pathValue) {
      errors.push(`${label} fileName must be a safe relative path`);
      continue;
    }
    if (seen.has(pathValue)) errors.push(`${label} duplicates ${pathValue}`);
    seen.add(pathValue);
    const path = join(root, ...pathValue.split("/"));
    if (!isInside(root, path)) {
      errors.push(`${label} escapes the published layout`);
      continue;
    }
    const snapshot = snapshotFile(path);
    if (!snapshot) {
      errors.push(`${label} is missing from the published layout: ${pathValue}`);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(entry?.sha256 ?? "")) {
      errors.push(`${label} sha256 must be lowercase SHA-256`);
    } else if (snapshot.sha256 !== entry.sha256) {
      errors.push(`${label} sha256 mismatch: ${pathValue}`);
    }
    if (!Number.isInteger(entry?.sizeBytes) || entry.sizeBytes !== snapshot.sizeBytes) {
      errors.push(`${label} sizeBytes mismatch: ${pathValue}`);
    }
    if (pathValue === REQUIRED_ENGINE) engineEntry = true;
    for (const bundle of REQUIRED_RESOURCE_BUNDLES) {
      if (pathValue.startsWith(`${bundle}/`)) resourceEntries.add(bundle);
    }
  }

  if (!engineEntry) errors.push(`${REQUIRED_ENGINE} is absent from the manifest`);
  for (const bundle of REQUIRED_RESOURCE_BUNDLES) {
    const resourceDirectory = join(root, bundle);
    let resourceDirectoryPresent = false;
    try {
      resourceDirectoryPresent = lstatSync(resourceDirectory).isDirectory();
    } catch {
      resourceDirectoryPresent = false;
    }
    if (!resourceDirectoryPresent) errors.push(`${bundle} directory is missing`);
    if (!resourceEntries.has(bundle)) errors.push(`${bundle} has no manifest entry`);
  }
  return { ok: errors.length === 0, errors };
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  const layoutDirectory = process.argv[2];
  if (!layoutDirectory) {
    console.error("Usage: validate-native-engine-layout.mjs <publish-directory>");
    process.exit(2);
  }
  const result = validateNativeEngineLayout(layoutDirectory);
  if (!result.ok) {
    for (const error of result.errors) console.error(`FAIL: ${error}`);
    process.exit(1);
  }
  const bundles = REQUIRED_RESOURCE_BUNDLES
    .map((bundle) => relative(resolve(layoutDirectory), join(resolve(layoutDirectory), bundle)))
    .join(", ");
  console.log(`PASS: native engine published layout is complete (${bundles})`);
}
