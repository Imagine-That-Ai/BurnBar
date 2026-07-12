#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const REQUIRED_RESOURCE_BUNDLE = "OpenBurnBarCore_OpenBurnBarCore.resources";
const REQUIRED_ENGINE = "OpenBurnBarCoreCAbi.dll";

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
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
  if (!existsSync(manifestPath) || !lstatSync(manifestPath).isFile()) {
    return { ok: false, errors: ["native-engine-manifest.json is missing"] };
  }

  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
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
  let resourceEntry = false;
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
    if (!existsSync(path) || !lstatSync(path).isFile()) {
      errors.push(`${label} is missing from the published layout: ${pathValue}`);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(entry?.sha256 ?? "")) {
      errors.push(`${label} sha256 must be lowercase SHA-256`);
    } else if (sha256(path) !== entry.sha256) {
      errors.push(`${label} sha256 mismatch: ${pathValue}`);
    }
    if (!Number.isInteger(entry?.sizeBytes) || entry.sizeBytes !== lstatSync(path).size) {
      errors.push(`${label} sizeBytes mismatch: ${pathValue}`);
    }
    if (pathValue === REQUIRED_ENGINE) engineEntry = true;
    if (pathValue.startsWith(`${REQUIRED_RESOURCE_BUNDLE}/`)) resourceEntry = true;
  }

  const resourceDirectory = join(root, REQUIRED_RESOURCE_BUNDLE);
  if (!existsSync(resourceDirectory) || !lstatSync(resourceDirectory).isDirectory()) {
    errors.push(`${REQUIRED_RESOURCE_BUNDLE} directory is missing`);
  }
  if (!engineEntry) errors.push(`${REQUIRED_ENGINE} is absent from the manifest`);
  if (!resourceEntry) errors.push(`${REQUIRED_RESOURCE_BUNDLE} has no manifest entry`);
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
  console.log(`PASS: native engine published layout is complete (${relative(resolve(layoutDirectory), join(resolve(layoutDirectory), REQUIRED_RESOURCE_BUNDLE))})`);
}
