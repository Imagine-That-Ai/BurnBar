#!/usr/bin/env node
/**
 * The customer-facing macOS download URL must be a first-party host. The
 * storage bucket may still be R2 behind Cloudflare, but raw r2.dev bucket URLs
 * should not appear in public site config or operator defaults.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const REPO_ROOT = path.resolve(ROOT, "..");

function read(relativePath) {
  return readFileSync(path.join(REPO_ROOT, relativePath), "utf8");
}

function stringValue(source, key) {
  const match = source.match(new RegExp(`${key}:\\s*"([^"]+)"`));
  assert(match, `SITE.${key} is missing`);
  return match[1];
}

const siteSource = read("website/src/data/site.ts");
const downloadPage = read("website/src/pages/download.astro");
const sourcePage = read("website/src/pages/legal/source.astro");
const uploadScript = read("scripts/upload-macos-downloads-r2.sh");
const releaseDocs = read("docs/RELEASE_MACOS.md");

const macDownloadBaseUrl = new URL(stringValue(siteSource, "macDownloadBaseUrl"));
assert.equal(
  macDownloadBaseUrl.hostname,
  "downloads.burnbar.ai",
  "SITE.macDownloadBaseUrl must use the first-party branded download host"
);
assert(
  !/(^|\.)r2\.dev$/i.test(macDownloadBaseUrl.hostname),
  "SITE.macDownloadBaseUrl must not expose a raw R2 public bucket"
);

const macUpdateBaseUrl = new URL(stringValue(siteSource, "macUpdateBaseUrl"));
assert(
  macUpdateBaseUrl.hostname === "github.com" || macUpdateBaseUrl.hostname === macDownloadBaseUrl.hostname,
  "SITE.macUpdateBaseUrl must be GitHub Releases or the first-party download host"
);

assert.match(downloadPage, /SHA-256 and SHA-512 checksums/);
assert.match(downloadPage, /SPDX SBOM/);
assert.match(sourcePage, /corresponding source archive/);
assert.match(sourcePage, /signed macOS DMG, ZIP, SBOM, checksums, and release\s+metadata/);

assert.match(
  uploadScript,
  /site_mac_download_base_url=/,
  "upload script must derive the verification URL from site config by default"
);
assert.match(
  uploadScript,
  /public_base_url="\$\{OPENBURNBAR_R2_PUBLIC_BASE_URL:-\$site_mac_download_base_url\}"/,
  "upload script must verify the configured public download host unless explicitly overridden"
);

assert.match(releaseDocs, /downloads\.burnbar\.ai/);
assert(
  !/Public R2 URL:\s*`https:\/\/[^`]+\.r2\.dev`/.test(releaseDocs),
  "release docs must not present raw r2.dev as the customer-facing public download URL"
);

console.log("download-provenance: first-party Mac download host and release provenance copy are guarded");
