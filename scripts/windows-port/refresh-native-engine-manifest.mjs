#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const REQUIRED_RESOURCE_BUNDLE = "OpenBurnBarCore_OpenBurnBarCore.resources";
export const REQUIRED_ENGINE = "OpenBurnBarCoreCAbi.dll";

function normalizedRelativePath(value) {
  if (typeof value !== "string" || value.length === 0 || isAbsolute(value)) return null;
  const normalized = value.replaceAll("\\", "/");
  if (normalized.split("/").some((part) => part === ".." || part.length === 0)) return null;
  return normalized;
}

function isInside(root, path) {
  const rootPath = resolve(root);
  const filePath = resolve(path);
  return filePath === rootPath || filePath.startsWith(`${rootPath}${sep}`);
}

function snapshotFile(root, relativePath) {
  const path = join(root, ...relativePath.split("/"));
  if (!isInside(root, path)) throw new Error(`manifest path escapes the layout: ${relativePath}`);
  let stat;
  try {
    stat = lstatSync(path);
  } catch {
    throw new Error(`manifest file is missing from the layout: ${relativePath}`);
  }
  if (!stat.isFile()) throw new Error(`manifest path is not a regular file: ${relativePath}`);
  const data = readFileSync(path);
  return {
    sha256: createHash("sha256").update(data).digest("hex"),
    sizeBytes: data.byteLength,
  };
}

export function refreshNativeEngineManifest(layoutDirectory) {
  const root = resolve(layoutDirectory);
  const manifestPath = join(root, "native-engine-manifest.json");
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`native-engine-manifest.json is invalid or missing: ${error.message}`);
  }

  if (manifest.schemaVersion !== 1) throw new Error("manifest schemaVersion must be 1");
  if (manifest.engine !== REQUIRED_ENGINE) throw new Error(`manifest engine must be ${REQUIRED_ENGINE}`);
  if (!Array.isArray(manifest.files) || manifest.files.length === 0) {
    throw new Error("manifest files must be a non-empty array");
  }

  const seen = new Set();
  let engineEntry = false;
  let resourceEntry = false;
  const files = manifest.files.map((entry, index) => {
    const label = `manifest files[${index}]`;
    const relativePath = normalizedRelativePath(entry?.fileName);
    if (!relativePath) throw new Error(`${label} fileName must be a safe relative path`);
    if (seen.has(relativePath)) throw new Error(`${label} duplicates ${relativePath}`);
    seen.add(relativePath);
    const snapshot = snapshotFile(root, relativePath);
    if (relativePath === REQUIRED_ENGINE) engineEntry = true;
    if (relativePath.startsWith(`${REQUIRED_RESOURCE_BUNDLE}/`)) resourceEntry = true;
    return { ...entry, fileName: relativePath, ...snapshot };
  });

  const resourceDirectory = join(root, REQUIRED_RESOURCE_BUNDLE);
  let resourceDirectoryPresent = false;
  try {
    resourceDirectoryPresent = lstatSync(resourceDirectory).isDirectory();
  } catch {
    resourceDirectoryPresent = false;
  }
  if (!resourceDirectoryPresent) throw new Error(`${REQUIRED_RESOURCE_BUNDLE} directory is missing`);
  if (!engineEntry) throw new Error(`${REQUIRED_ENGINE} is absent from the manifest`);
  if (!resourceEntry) throw new Error(`${REQUIRED_RESOURCE_BUNDLE} has no manifest entry`);

  const refreshed = { ...manifest, files };
  writeFileSync(manifestPath, `${JSON.stringify(refreshed, null, 2)}\n`, "utf8");
  return refreshed;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  const layoutDirectory = process.argv[2];
  if (!layoutDirectory) {
    console.error("Usage: refresh-native-engine-manifest.mjs <publish-directory>");
    process.exit(2);
  }
  try {
    const manifest = refreshNativeEngineManifest(layoutDirectory);
    console.log(`PASS: refreshed native-engine manifest (${manifest.files.length} files)`);
  } catch (error) {
    console.error(`FAIL: ${error.message}`);
    process.exit(1);
  }
}
