#!/usr/bin/env node
/**
 * The customer-facing macOS download URL must either be the first-party
 * downloads host or an actual GitHub Release asset. Raw storage bucket URLs and
 * unpublished/dead hostnames must not appear in public site config.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
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

// This is intentionally duplicated from SITE. Changing the public DMG URL must
// update this audited live URL in the same PR, after the replacement artifact is
// published and manually verified.
const AUDITED_LIVE_MAC_DOWNLOAD_URL = "https://downloads.burnbar.ai/OpenBurnBar-1.0.40+repair.34-macOS.dmg";

const TRUSTED_GITHUB_RELEASE_PATH =
  /^\/Imagine-That-Ai\/BurnBar\/releases\/download\/[^/]+(?:\/OpenBurnBar-[A-Za-z0-9._+-]+-macOS\.dmg)?$/;

function assertHttpsDownloadUrl(url, label) {
  assert.equal(url.protocol, "https:", `${label} must use HTTPS`);
  assert.equal(url.username, "", `${label} must not contain a username`);
  assert.equal(url.password, "", `${label} must not contain a password`);
  assert.equal(url.search, "", `${label} must not contain query parameters`);
  assert.equal(url.hash, "", `${label} must not contain a fragment`);

  if (url.hostname === "downloads.burnbar.ai") {
    assert(
      /^\/(?:OpenBurnBar-[A-Za-z0-9._+-]+-macOS\.dmg)?$/.test(url.pathname),
      `${label} must stay on the first-party download root or macOS DMG asset`
    );
    return;
  }

  if (url.hostname === "github.com") {
    assert(
      TRUSTED_GITHUB_RELEASE_PATH.test(url.pathname),
      `${label} must stay on the BurnBar GitHub Release asset path`
    );
    return;
  }

  assert.fail(`${label} must use downloads.burnbar.ai or a GitHub Release asset path`);
}

const macDownloadBaseUrl = new URL(stringValue(siteSource, "macDownloadBaseUrl"));
const macReleaseFile = stringValue(siteSource, "macReleaseFile");
assert.match(
  macReleaseFile,
  /^OpenBurnBar-[A-Za-z0-9._+-]+-macOS\.dmg$/,
  "SITE.macReleaseFile must be a plain OpenBurnBar macOS DMG filename"
);
assertHttpsDownloadUrl(macDownloadBaseUrl, "SITE.macDownloadBaseUrl");
assert(
  !/(^|\.)r2\.dev$/i.test(macDownloadBaseUrl.hostname),
  "SITE.macDownloadBaseUrl must not expose a raw R2 public bucket"
);

const macDownloadUrl = new URL(
  `${macDownloadBaseUrl.toString().replace(/\/$/, "")}/${macReleaseFile}`
);
assertHttpsDownloadUrl(macDownloadUrl, "SITE macOS download URL");
assert.equal(
  macDownloadUrl.href,
  AUDITED_LIVE_MAC_DOWNLOAD_URL,
  "SITE macOS download URL must match the audited live DMG URL in this smoke test"
);

async function fetchAuditedMacDownloadWithTimeout(init) {
  const response = await fetch(AUDITED_LIVE_MAC_DOWNLOAD_URL, {
    redirect: "follow",
    signal: AbortSignal.timeout(15_000),
    ...init
  });
  return response;
}

async function cancelBody(response) {
  await response.body?.cancel().catch(() => {});
}

async function assertLiveDownloadUrl() {
  let lastFailure = "not attempted";
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const head = await fetchAuditedMacDownloadWithTimeout({ method: "HEAD" });
      if (head.ok) return;

      lastFailure = `HEAD returned ${head.status}`;
      if (head.status === 403 || head.status === 405) {
        const ranged = await fetchAuditedMacDownloadWithTimeout({
          method: "GET",
          headers: { Range: "bytes=0-0" }
        });
        const ok = ranged.ok || ranged.status === 206;
        lastFailure = `GET range returned ${ranged.status}`;
        await cancelBody(ranged);
        if (ok) return;
      }
    } catch (error) {
      lastFailure = error instanceof Error ? error.message : String(error);
    }

    if (attempt < 3) await delay(attempt * 750);
  }

  assert.fail(
    `SITE macOS download URL must be live: ${AUDITED_LIVE_MAC_DOWNLOAD_URL} (${lastFailure})`
  );
}

await assertLiveDownloadUrl();

const macUpdateBaseUrlRaw = stringValue(siteSource, "macUpdateBaseUrl");
if (macUpdateBaseUrlRaw) {
  const macUpdateBaseUrl = new URL(macUpdateBaseUrlRaw);
  assert(
    macUpdateBaseUrl.hostname === "github.com" ||
      macUpdateBaseUrl.hostname === macDownloadBaseUrl.hostname,
    "SITE.macUpdateBaseUrl must be GitHub Releases or the first-party download host"
  );
}

assert.match(downloadPage, /macOS DMG is served from OpenBurnBar's first-party download host/);
assert.match(downloadPage, /checksum\s+matches the immutable GitHub Release asset/);
assert.match(
  downloadPage,
  /<BaseLayout[\s\S]*?ambientEffects=\{false\}[\s\S]*?>/,
  "download page must suppress ambient canvases so platform choices stay visually unobstructed"
);
assert.match(
  downloadPage,
  /<h1 class="pagehead__h" data-pretext-native>[\s\S]*?<span>Get<\/span>[\s\S]*?<span class="pagehead__product">OpenBurnBar<\/span>[\s\S]*?<\/h1>/,
  "download hero must keep the product name as one non-breaking visual unit"
);
assert.match(
  downloadPage,
  /\.pagehead__product \{[^}]*white-space: nowrap;/,
  "download hero product name must not split mid-word on narrow screens"
);
assert.doesNotMatch(
  downloadPage,
  /Get OpenBurnBar\.<\/h1>/,
  "download hero punctuation must not wrap onto its own line on narrow screens"
);
assert.match(downloadPage, /First-party download host with immutable release provenance/);
assert.match(downloadPage, /Developer ID signed, notarized, and stapled/);
assert.doesNotMatch(
  downloadPage,
  /branded\s+direct-download host is being republished/,
  "the live first-party download host must not be described as unavailable"
);
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
