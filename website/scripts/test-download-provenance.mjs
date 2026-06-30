#!/usr/bin/env node
/**
 * The customer-facing macOS download URL must either be the first-party
 * downloads host or an actual GitHub Release asset. Raw storage bucket URLs and
 * unpublished/dead hostnames must not appear in public site config.
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
  const match = source.match(new RegExp(`${key}:\\s*"([^"]*)"`));
  assert(match, `SITE.${key} is missing`);
  return match[1];
}

const siteSource = read("website/src/data/site.ts");
const downloadPage = read("website/src/pages/download.astro");
const sourcePage = read("website/src/pages/legal/source.astro");
const uploadScript = read("scripts/upload-macos-downloads-r2.sh");
const releaseDocs = read("docs/RELEASE_MACOS.md");

const macDownloadBaseUrl = new URL(stringValue(siteSource, "macDownloadBaseUrl"));
const macReleaseFile = stringValue(siteSource, "macReleaseFile");
const isFirstPartyDownloadHost = macDownloadBaseUrl.hostname === "downloads.burnbar.ai";
const isGitHubReleaseAsset =
  macDownloadBaseUrl.hostname === "github.com" &&
  macDownloadBaseUrl.pathname.startsWith("/Imagine-That-Ai/BurnBar/releases/download/");
assert(
  isFirstPartyDownloadHost || isGitHubReleaseAsset,
  "SITE.macDownloadBaseUrl must use downloads.burnbar.ai or a GitHub Release asset path"
);
assert(
  !/(^|\.)r2\.dev$/i.test(macDownloadBaseUrl.hostname),
  "SITE.macDownloadBaseUrl must not expose a raw R2 public bucket"
);

const macDownloadUrl = new URL(
  `${macDownloadBaseUrl.toString().replace(/\/$/, "")}/${macReleaseFile}`
);
const macDownloadResponse = await fetch(macDownloadUrl, {
  method: "HEAD",
  redirect: "follow",
  signal: AbortSignal.timeout(15_000)
});
assert(
  macDownloadResponse.ok,
  `SITE macOS download URL must be live: ${macDownloadUrl} returned ${macDownloadResponse.status}`
);

const macUpdateBaseUrlRaw = stringValue(siteSource, "macUpdateBaseUrl");
if (macUpdateBaseUrlRaw) {
  const macUpdateBaseUrl = new URL(macUpdateBaseUrlRaw);
  assert(
    macUpdateBaseUrl.hostname === "github.com" ||
      macUpdateBaseUrl.hostname === macDownloadBaseUrl.hostname,
    "SITE.macUpdateBaseUrl must be GitHub Releases or the first-party download host"
  );
}

assert.match(downloadPage, /public macOS DMG is served from GitHub Releases/);
assert.match(downloadPage, /branded\s+direct-download host is being republished/);
assert.match(sourcePage, /corresponding source archive/);
assert.match(sourcePage, /signed macOS\s+DMG, ZIP, SBOM, checksums, and release\s+metadata/);

assert.match(
  uploadScript,
  /public_base_url="\$\{OPENBURNBAR_R2_PUBLIC_BASE_URL:-https:\/\/downloads\.burnbar\.ai\}"/,
  "upload script must verify the branded download host by default, not a temporary website fallback"
);
assert.match(
  uploadScript,
  /OPENBURNBAR_R2_PUBLIC_BASE_URL/,
  "upload script must allow operators to override the branded public verification host"
);

assert.match(releaseDocs, /downloads\.burnbar\.ai/);
assert(
  !/Public R2 URL:\s*`https:\/\/[^`]+\.r2\.dev`/.test(releaseDocs),
  "release docs must not present raw r2.dev as the customer-facing public download URL"
);

console.log("download-provenance: Mac download host and release provenance copy are guarded");
