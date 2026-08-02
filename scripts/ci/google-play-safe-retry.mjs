#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  openSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { basename } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const DEFAULT_API_ROOT =
  "https://androidpublisher.googleapis.com/androidpublisher/v3";
const DEFAULT_UPLOAD_ROOT =
  "https://androidpublisher.googleapis.com/upload/androidpublisher/v3";
const MUTABLE_RELEASE_STATUSES = new Set(["draft", "inProgress", "halted"]);
const ALLOWED_REQUESTED_STATUSES = new Set(["draft", "completed"]);

function requiredNext(argv, index, flag) {
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function parseArgs(argv) {
  const options = {
    manifestPath: "",
    aabPath: "",
    outputPath: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--manifest") {
      options.manifestPath = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--aab") {
      options.aabPath = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--output") {
      options.outputPath = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!options.manifestPath) throw new Error("--manifest is required");
  if (!options.aabPath) throw new Error("--aab is required");
  if (!options.outputPath) throw new Error("--output is required");
  return options;
}

function printHelp() {
  process.stdout.write(`Usage:
  ACCESS_TOKEN=... node google-play-safe-retry.mjs \\
    --manifest google-play-publication.json \\
    --aab OpenBurnBar.aab \\
    --output google-play-provider-result.json
`);
}

export function parseVersionCode(value) {
  const rendered = String(value).trim();
  if (!/^[1-9][0-9]{0,9}$/u.test(rendered)) {
    throw new Error(`Invalid positive Android version code: ${value}`);
  }
  const parsed = Number.parseInt(rendered, 10);
  if (!Number.isSafeInteger(parsed) || parsed > 2_100_000_000) {
    throw new Error(
      `Android version code is outside Google Play's accepted range: ${value}`,
    );
  }
  return parsed;
}

export function versionCodesFromTrack(track) {
  return [
    ...new Set(
      (track?.releases ?? [])
        .flatMap((release) => release?.versionCodes ?? [])
        .map(parseVersionCode),
    ),
  ].sort((left, right) => left - right);
}

export function planTrackUpdate(
  track,
  expectedVersionCode,
  releaseName,
  requestedStatus,
) {
  const expected = parseVersionCode(expectedVersionCode);
  if (!ALLOWED_REQUESTED_STATUSES.has(requestedStatus)) {
    throw new Error(`Unsupported Google Play release status: ${requestedStatus}`);
  }

  const releases = track?.releases ?? [];
  const priorVersionCodes = versionCodesFromTrack(track);
  const newerVersionCode = priorVersionCodes.find((code) => code > expected);
  if (newerVersionCode) {
    throw new Error(
      `Refusing Google Play rollback: ${track?.track ?? "requested track"} already contains newer version code ${newerVersionCode}`,
    );
  }

  const unrelatedMutableRelease = releases.find((release) => {
    if (!MUTABLE_RELEASE_STATUSES.has(release?.status)) return false;
    const codes = (release?.versionCodes ?? []).map(parseVersionCode);
    return !codes.includes(expected);
  });
  if (unrelatedMutableRelease) {
    const codes =
      (unrelatedMutableRelease.versionCodes ?? []).join(",") || "unknown";
    throw new Error(
      `Refusing to replace unrelated ${unrelatedMutableRelease.status} Google Play release with version code(s) ${codes}`,
    );
  }

  const exactCompletedRelease =
    releases.find(
      (release) =>
        release?.status === "completed" &&
        (release?.versionCodes ?? []).map(parseVersionCode).includes(expected),
    ) ?? null;
  if (exactCompletedRelease) {
    return {
      action: "already_current",
      updateRequired: false,
      requestedStatus,
      readbackStatus: "completed",
      priorVersionCodes,
      exactCompletedRelease,
      requestBody: null,
    };
  }

  return {
    action: "update_track",
    updateRequired: true,
    requestedStatus,
    readbackStatus: requestedStatus,
    priorVersionCodes,
    exactCompletedRelease: null,
    requestBody: {
      track: track?.track,
      releases: [
        {
          name: releaseName,
          versionCodes: [String(expected)],
          status: requestedStatus,
        },
      ],
    },
  };
}

function validateManifest(manifest, aabPath) {
  assert.equal(manifest?.schemaVersion, 1, "Unsupported publication manifest");
  assert.equal(
    manifest?.publication?.packageName,
    "com.openburnbar",
    "Unexpected Android package",
  );
  assert.equal(
    manifest?.publication?.dryRun,
    false,
    "Provider publisher cannot execute a dry-run manifest",
  );
  const track = String(manifest?.publication?.track ?? "");
  if (!/^(internal|alpha|beta|production)$/u.test(track)) {
    throw new Error(`Unsupported Google Play track: ${track}`);
  }
  const releaseStatus = String(
    manifest?.publication?.releaseStatus ?? "",
  );
  if (!ALLOWED_REQUESTED_STATUSES.has(releaseStatus)) {
    throw new Error(`Unsupported Google Play release status: ${releaseStatus}`);
  }
  const expectedVersionCode = parseVersionCode(
    manifest?.release?.versionCode,
  );
  const versionName = String(manifest?.release?.versionName ?? "").trim();
  if (!versionName) throw new Error("Publication versionName is required");
  const expectedSha256 = String(manifest?.artifact?.sha256 ?? "").toLowerCase();
  if (!/^[0-9a-f]{64}$/u.test(expectedSha256)) {
    throw new Error("Publication manifest has an invalid AAB SHA-256");
  }
  const expectedFileName = String(manifest?.artifact?.fileName ?? "");
  if (basename(aabPath) !== expectedFileName) {
    throw new Error(
      `AAB filename ${basename(aabPath)} does not match publication manifest ${expectedFileName}`,
    );
  }
  return {
    packageName: manifest.publication.packageName,
    track,
    releaseStatus,
    expectedVersionCode,
    versionName,
    releaseName: `OpenBurnBar ${versionName}`,
    expectedSha256,
  };
}

function readRegularAab(aabPath) {
  if (!aabPath.endsWith(".aab")) {
    throw new Error(`Android App Bundle must end in .aab: ${aabPath}`);
  }
  let fd;
  try {
    fd = openSync(aabPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error(`Android App Bundle does not exist: ${aabPath}`);
    }
    if (error?.code === "ELOOP") {
      throw new Error(
        `Android App Bundle must be a non-empty regular file: ${aabPath}`,
      );
    }
    throw error;
  }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size <= 0) {
      throw new Error(
        `Android App Bundle must be a non-empty regular file: ${aabPath}`,
      );
    }
    const bytes = readFileSync(fd);
    return {
      bytes,
      sizeBytes: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    };
  } finally {
    closeSync(fd);
  }
}

function encodedPath(value) {
  return encodeURIComponent(value);
}

function responseErrorBody(text) {
  try {
    const parsed = JSON.parse(text);
    return parsed?.error?.message ?? text;
  } catch {
    return text;
  }
}

async function requestJson(
  fetchImpl,
  accessToken,
  url,
  { method = "GET", body, contentType } = {},
) {
  const headers = {
    Authorization: `Bearer ${accessToken}`,
  };
  if (contentType) headers["Content-Type"] = contentType;
  const timeoutMs =
    contentType === "application/octet-stream" ? 600_000 : 120_000;
  const response = await fetchImpl(url, {
    method,
    headers,
    body,
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      `Google Play ${method} ${url} failed with HTTP ${response.status}: ${responseErrorBody(text) || "empty response"}`,
    );
  }
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(
      `Google Play ${method} ${url} returned invalid JSON after HTTP ${response.status}`,
    );
  }
}

function findExpectedBundle(bundles, expectedVersionCode) {
  const expected = parseVersionCode(expectedVersionCode);
  return (
    (bundles ?? []).find(
      (bundle) => parseVersionCode(bundle?.versionCode) === expected,
    ) ?? null
  );
}

function assertExistingBundleBytes(bundle, expectedVersionCode, aabSha256) {
  const expected = parseVersionCode(expectedVersionCode);
  const reported = String(bundle?.sha256 ?? "").toLowerCase();
  if (!/^[0-9a-f]{64}$/u.test(reported)) {
    throw new Error(
      `Google Play did not report a SHA-256 for existing bundle ${expected}; refusing to reuse it`,
    );
  }
  if (reported !== aabSha256) {
    throw new Error(
      `Google Play bundle ${expected} SHA-256 ${reported} does not match sealed AAB SHA-256 ${aabSha256}; refusing to reuse different bytes`,
    );
  }
}

function assertTrackReadback(
  track,
  expectedVersionCode,
  expectedStatus,
) {
  const expected = parseVersionCode(expectedVersionCode);
  const versionCodes = versionCodesFromTrack(track);
  const newerVersionCode = versionCodes.find((code) => code > expected);
  if (newerVersionCode) {
    throw new Error(
      `Google Play readback unexpectedly contains newer version code ${newerVersionCode}`,
    );
  }
  const release = (track?.releases ?? []).find(
    (candidate) =>
      candidate?.status === expectedStatus &&
      (candidate?.versionCodes ?? []).map(parseVersionCode).includes(expected),
  );
  if (!release) {
    throw new Error(
      `Google Play readback did not contain ${expectedStatus} version code ${expected} on ${track?.track ?? "requested track"}`,
    );
  }
  return {
    track: track.track,
    status: release.status,
    versionCodes,
    releaseName: release.name ?? null,
  };
}

function isNotFound(error) {
  return /\bHTTP 404\b/u.test(String(error?.message ?? ""));
}

async function getTrack({
  fetchImpl,
  accessToken,
  apiRoot,
  packageName,
  editId,
  track,
}) {
  const url = `${apiRoot}/applications/${encodedPath(packageName)}/edits/${encodedPath(editId)}/tracks/${encodedPath(track)}`;
  try {
    return await requestJson(fetchImpl, accessToken, url);
  } catch (error) {
    if (isNotFound(error)) return { track, releases: [] };
    throw error;
  }
}

async function deleteEditQuietly({
  fetchImpl,
  accessToken,
  apiRoot,
  packageName,
  editId,
}) {
  if (!editId) return;
  const url = `${apiRoot}/applications/${encodedPath(packageName)}/edits/${encodedPath(editId)}`;
  try {
    await requestJson(fetchImpl, accessToken, url, { method: "DELETE" });
  } catch (error) {
    if (!isNotFound(error)) {
      process.stderr.write(
        `warning: unable to delete Google Play edit ${editId}: ${error.message}\n`,
      );
    }
  }
}

async function insertEdit({
  fetchImpl,
  accessToken,
  apiRoot,
  packageName,
}) {
  const url = `${apiRoot}/applications/${encodedPath(packageName)}/edits`;
  const inserted = await requestJson(fetchImpl, accessToken, url, {
    method: "POST",
    contentType: "application/json",
    body: "{}",
  });
  const editId = String(inserted?.id ?? "");
  if (!editId) throw new Error("Google Play did not return an edit id");
  return { editId, response: inserted };
}

export async function publishGooglePlayRelease({
  fetchImpl,
  accessToken,
  manifest,
  aabPath,
  apiRoot = DEFAULT_API_ROOT,
  uploadRoot = DEFAULT_UPLOAD_ROOT,
}) {
  if (typeof fetchImpl !== "function") {
    throw new Error("A fetch implementation is required");
  }
  if (!String(accessToken ?? "").trim()) {
    throw new Error("A Google Play access token is required");
  }
  const publication = validateManifest(manifest, aabPath);
  const aab = readRegularAab(aabPath);
  if (aab.sha256 !== publication.expectedSha256) {
    throw new Error(
      `Sealed AAB SHA-256 ${aab.sha256} does not match publication manifest ${publication.expectedSha256}`,
    );
  }

  const common = {
    fetchImpl,
    accessToken,
    apiRoot,
    packageName: publication.packageName,
  };
  let publicationEditId = "";
  let readbackEditId = "";
  let committed = false;

  try {
    const inserted = await insertEdit(common);
    publicationEditId = inserted.editId;
    const editRoot = `${apiRoot}/applications/${encodedPath(publication.packageName)}/edits/${encodedPath(publicationEditId)}`;
    const [bundleList, priorTrack] = await Promise.all([
      requestJson(
        fetchImpl,
        accessToken,
        `${editRoot}/bundles`,
      ),
      getTrack({
        ...common,
        editId: publicationEditId,
        track: publication.track,
      }),
    ]);
    const existingBundle = findExpectedBundle(
      bundleList?.bundles,
      publication.expectedVersionCode,
    );
    if (existingBundle) {
      assertExistingBundleBytes(
        existingBundle,
        publication.expectedVersionCode,
        aab.sha256,
      );
    }

    const plan = planTrackUpdate(
      priorTrack,
      publication.expectedVersionCode,
      publication.releaseName,
      publication.releaseStatus,
    );
    if (!plan.updateRequired && !existingBundle) {
      throw new Error(
        `Google Play track contains completed version code ${publication.expectedVersionCode}, but the edit bundle list does not contain that bundle; refusing an unverifiable no-op`,
      );
    }

    let uploadedBundle = null;
    if (!existingBundle && plan.updateRequired) {
      uploadedBundle = await requestJson(
        fetchImpl,
        accessToken,
        `${uploadRoot}/applications/${encodedPath(publication.packageName)}/edits/${encodedPath(publicationEditId)}/bundles?uploadType=media`,
        {
          method: "POST",
          contentType: "application/octet-stream",
          body: aab.bytes,
        },
      );
      const uploadedVersionCode = parseVersionCode(
        uploadedBundle?.versionCode,
      );
      if (uploadedVersionCode !== publication.expectedVersionCode) {
        throw new Error(
          `Google Play uploaded version code ${uploadedVersionCode}, expected ${publication.expectedVersionCode}`,
        );
      }
    }

    if (!plan.updateRequired) {
      const noOpEditId = publicationEditId;
      await deleteEditQuietly({ ...common, editId: publicationEditId });
      publicationEditId = "";
      const readbackEdit = await insertEdit(common);
      readbackEditId = readbackEdit.editId;
      const readbackTrack = await getTrack({
        ...common,
        editId: readbackEditId,
        track: publication.track,
      });
      const readback = assertTrackReadback(
        readbackTrack,
        publication.expectedVersionCode,
        plan.readbackStatus,
      );
      await deleteEditQuietly({ ...common, editId: readbackEditId });
      readbackEditId = "";
      return {
        schemaVersion: 1,
        action: "already_current",
        packageName: publication.packageName,
        track: publication.track,
        requestedReleaseStatus: publication.releaseStatus,
        versionName: publication.versionName,
        versionCode: publication.expectedVersionCode,
        uploaded: false,
        committed: false,
        committedEditId: null,
        inspectedEditId: noOpEditId,
        priorVersionCodes: plan.priorVersionCodes,
        aab: {
          fileName: basename(aabPath),
          sizeBytes: aab.sizeBytes,
          sha256: aab.sha256,
        },
        readback,
        providerResponses: {
          edit: inserted.response,
          bundles: bundleList,
          priorTrack,
          existingBundle,
          uploadedBundle: null,
          trackUpdate: null,
          commit: null,
          readbackEdit: readbackEdit.response,
          readbackTrack,
        },
      };
    }

    const trackUpdate = await requestJson(
      fetchImpl,
      accessToken,
      `${editRoot}/tracks/${encodedPath(publication.track)}`,
      {
        method: "PUT",
        contentType: "application/json",
        body: JSON.stringify(plan.requestBody),
      },
    );
    const commitResponse = await requestJson(
      fetchImpl,
      accessToken,
      `${editRoot}:commit`,
      { method: "POST" },
    );
    committed = true;
    const committedEditId = publicationEditId;
    publicationEditId = "";

    const readbackEdit = await insertEdit(common);
    readbackEditId = readbackEdit.editId;
    const readbackTrack = await getTrack({
      ...common,
      editId: readbackEditId,
      track: publication.track,
    });
    const readback = assertTrackReadback(
      readbackTrack,
      publication.expectedVersionCode,
      plan.readbackStatus,
    );
    await deleteEditQuietly({ ...common, editId: readbackEditId });
    readbackEditId = "";

    return {
      schemaVersion: 1,
      action: uploadedBundle
        ? "uploaded_and_committed"
        : "existing_bundle_committed",
      packageName: publication.packageName,
      track: publication.track,
      requestedReleaseStatus: publication.releaseStatus,
      versionName: publication.versionName,
      versionCode: publication.expectedVersionCode,
      uploaded: Boolean(uploadedBundle),
      committed,
      committedEditId,
      inspectedEditId: committedEditId,
      priorVersionCodes: plan.priorVersionCodes,
      aab: {
        fileName: basename(aabPath),
        sizeBytes: aab.sizeBytes,
        sha256: aab.sha256,
      },
      readback,
      providerResponses: {
        edit: inserted.response,
        bundles: bundleList,
        priorTrack,
        existingBundle,
        uploadedBundle,
        trackUpdate,
        commit: commitResponse,
        readbackEdit: readbackEdit.response,
        readbackTrack,
      },
    };
  } finally {
    await deleteEditQuietly({ ...common, editId: publicationEditId });
    await deleteEditQuietly({ ...common, editId: readbackEditId });
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const accessToken = process.env.ACCESS_TOKEN?.trim();
  if (!accessToken) throw new Error("ACCESS_TOKEN is required");
  const manifest = JSON.parse(readFileSync(options.manifestPath, "utf8"));
  const result = await publishGooglePlayRelease({
    fetchImpl: globalThis.fetch,
    accessToken,
    manifest,
    aabPath: options.aabPath,
  });
  writeFileSync(options.outputPath, `${JSON.stringify(result, null, 2)}\n`, {
    mode: 0o600,
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    process.stderr.write(`${error.stack ?? error.message}\n`);
    process.exit(1);
  });
}
