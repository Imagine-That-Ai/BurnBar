#!/usr/bin/env node
/**
 * Publish one exact, signed Android App Bundle to the Google Play internal track.
 *
 * The caller must independently inspect the AAB and pass its embedded version
 * code. This script binds that expected code to the Play upload response and
 * committed track readback, refuses version-code rollback, and makes reruns
 * idempotent when the exact version is already current.
 */

import { createHash } from "node:crypto";
import {
  createReadStream,
  existsSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { basename } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);

const ANDROID_PUBLISHER_SCOPE =
  "https://www.googleapis.com/auth/androidpublisher";
const DEFAULT_PACKAGE_NAME = "com.openburnbar";
const DEFAULT_TRACK = "internal";
const REQUIRED_CONFIRMATION = "burnbar-google-play-internal";
const COMPLETED = "completed";
const MUTABLE_RELEASE_STATES = new Set(["draft", "inProgress", "halted"]);

function requiredNext(argv, index, flag) {
  const value = argv[index + 1];
  if (!value || value.startsWith("--"))
    throw new Error(`${flag} requires a value`);
  return value;
}

function parseArgs(argv) {
  const options = {
    aabPath: "",
    expectedVersionCode: null,
    versionName: "",
    releaseName: "",
    packageName: process.env.GOOGLE_PLAY_PACKAGE_NAME || DEFAULT_PACKAGE_NAME,
    track: process.env.GOOGLE_PLAY_TRACK || DEFAULT_TRACK,
    receiptPath: "",
    confirmation: "",
    json: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--aab") {
      options.aabPath = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--expected-version-code") {
      options.expectedVersionCode = parseVersionCode(
        requiredNext(argv, index, arg),
      );
      index += 1;
    } else if (arg === "--version-name") {
      options.versionName = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--release-name") {
      options.releaseName = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--package-name") {
      options.packageName = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--track") {
      options.track = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--receipt") {
      options.receiptPath = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--confirm-google-play-publish") {
      options.confirmation = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!options.aabPath) throw new Error("--aab is required");
  if (options.expectedVersionCode === null)
    throw new Error("--expected-version-code is required");
  if (!options.versionName.trim())
    throw new Error("--version-name is required");
  if (!options.releaseName.trim())
    options.releaseName = `OpenBurnBar ${options.versionName}`;
  if (!/^[a-z][a-z0-9._-]{2,149}$/u.test(options.packageName)) {
    throw new Error(`Invalid Google Play package name: ${options.packageName}`);
  }
  if (!/^[a-z][a-z0-9._-]{0,99}$/u.test(options.track)) {
    throw new Error(`Invalid Google Play track: ${options.track}`);
  }
  if (options.confirmation !== REQUIRED_CONFIRMATION) {
    throw new Error(
      `Refusing Google Play mutation without --confirm-google-play-publish ${REQUIRED_CONFIRMATION}`,
    );
  }
  return options;
}

function printHelp() {
  console.log(`Usage:
  node tools/google-play/publish-internal-release.mjs \\
    --aab OpenBurnBar.aab \\
    --expected-version-code 41 \\
    --version-name 1.0.31 \\
    --track internal \\
    --receipt google-play-release-receipt.json \\
    --confirm-google-play-publish ${REQUIRED_CONFIRMATION}

Environment:
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON  Full service-account JSON, or a JSON file path.
  GOOGLE_APPLICATION_CREDENTIALS    Service-account JSON path when the variable above is unset.
  GOOGLE_PLAY_PACKAGE_NAME          Defaults to ${DEFAULT_PACKAGE_NAME}.
  GOOGLE_PLAY_TRACK                 Defaults to ${DEFAULT_TRACK}.
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

export function planTrackUpdate(track, expectedVersionCode, releaseName) {
  const expected = parseVersionCode(expectedVersionCode);
  const releases = track?.releases ?? [];
  const currentCodes = versionCodesFromTrack(track);
  const newerCode = currentCodes.find((code) => code > expected);
  if (newerCode) {
    throw new Error(
      `Refusing Google Play rollback: ${track?.track ?? DEFAULT_TRACK} already contains newer version code ${newerCode}`,
    );
  }

  const conflictingMutable = releases.find((release) => {
    if (!MUTABLE_RELEASE_STATES.has(release?.status)) return false;
    return !(release?.versionCodes ?? [])
      .map(parseVersionCode)
      .includes(expected);
  });
  if (conflictingMutable) {
    throw new Error(
      `Refusing to replace ${conflictingMutable.status} Google Play release with version code(s) ${(conflictingMutable.versionCodes ?? []).join(",") || "unknown"}`,
    );
  }

  const exactCompleted = releases.some(
    (release) =>
      release?.status === COMPLETED &&
      (release?.versionCodes ?? []).map(parseVersionCode).includes(expected),
  );
  if (exactCompleted) {
    return {
      action: "already_current",
      updateRequired: false,
      requestBody: null,
      priorVersionCodes: currentCodes,
    };
  }

  return {
    action: "update_track",
    updateRequired: true,
    requestBody: {
      track: track?.track ?? DEFAULT_TRACK,
      releases: [
        {
          name: releaseName,
          versionCodes: [String(expected)],
          status: COMPLETED,
        },
      ],
    },
    priorVersionCodes: currentCodes,
  };
}

function loadCredentials() {
  const raw = process.env.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON?.trim();
  if (raw) {
    const json = raw.startsWith("{") ? raw : readFileSync(raw, "utf8");
    const credentials = JSON.parse(json);
    if (
      credentials.type !== "service_account" ||
      !credentials.client_email ||
      !credentials.private_key
    ) {
      throw new Error(
        "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is not a complete service-account credential",
      );
    }
    return { credentials };
  }

  const credentialsPath = process.env.GOOGLE_APPLICATION_CREDENTIALS?.trim();
  if (credentialsPath) {
    if (!existsSync(credentialsPath)) {
      throw new Error(
        `GOOGLE_APPLICATION_CREDENTIALS does not exist: ${credentialsPath}`,
      );
    }
    return { keyFile: credentialsPath };
  }
  throw new Error("Google Play service-account credentials are required");
}

async function createAndroidPublisher() {
  let google;
  try {
    ({ google } = require("../../functions/node_modules/googleapis"));
  } catch (error) {
    throw new Error(
      `Google API client is unavailable; run npm ci --prefix functions --omit=dev --ignore-scripts (${error.message})`,
    );
  }
  const auth = new google.auth.GoogleAuth({
    ...loadCredentials(),
    scopes: [ANDROID_PUBLISHER_SCOPE],
  });
  const authClient = await auth.getClient();
  return google.androidpublisher({ version: "v3", auth: authClient });
}

function regularAab(path) {
  if (!existsSync(path))
    throw new Error(`Android App Bundle does not exist: ${path}`);
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) {
    throw new Error(
      `Android App Bundle must be a non-empty regular file: ${path}`,
    );
  }
  if (!path.endsWith(".aab"))
    throw new Error(`Android App Bundle must end in .aab: ${path}`);
  return stat;
}

async function sha256File(path) {
  const hash = createHash("sha256");
  await new Promise((resolve, reject) => {
    const stream = createReadStream(path);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", resolve);
  });
  return hash.digest("hex");
}

function isNotFound(error) {
  const code = error?.code ?? error?.response?.status;
  return code === 404;
}

function googleErrorSummary(error) {
  const code = error?.code ?? error?.response?.status ?? "unknown";
  const message =
    error?.errors?.[0]?.message ??
    error?.response?.data?.error?.message ??
    error?.message ??
    "unknown";
  return `HTTP ${code}: ${message}`;
}

async function getTrack(androidpublisher, packageName, editId, track) {
  try {
    const response = await androidpublisher.edits.tracks.get({
      packageName,
      editId,
      track,
    });
    return response.data ?? { track, releases: [] };
  } catch (error) {
    if (isNotFound(error)) return { track, releases: [] };
    throw error;
  }
}

async function deleteEditQuietly(androidpublisher, packageName, editId) {
  if (!editId) return;
  try {
    await androidpublisher.edits.delete({ packageName, editId });
  } catch (error) {
    if (!isNotFound(error)) {
      console.error(
        `warning: unable to delete Google Play edit ${editId}: ${googleErrorSummary(error)}`,
      );
    }
  }
}

function bundleVersionCodes(bundles) {
  return new Set(
    (bundles ?? []).map((bundle) => parseVersionCode(bundle.versionCode)),
  );
}

function assertCommittedTrack(track, expectedVersionCode) {
  const expected = parseVersionCode(expectedVersionCode);
  const currentCodes = versionCodesFromTrack(track);
  const release = (track?.releases ?? []).find(
    (candidate) =>
      candidate?.status === COMPLETED &&
      (candidate?.versionCodes ?? []).map(parseVersionCode).includes(expected),
  );
  if (!release) {
    throw new Error(
      `Google Play readback did not contain completed version code ${expected} on ${track?.track ?? "unknown track"}`,
    );
  }
  const newerCode = currentCodes.find((code) => code > expected);
  if (newerCode) {
    throw new Error(
      `Google Play readback unexpectedly contains newer version code ${newerCode}`,
    );
  }
  return {
    track: track.track,
    status: release.status,
    versionCodes: currentCodes,
    releaseName: release.name ?? null,
  };
}

export async function publishInternalRelease({
  androidpublisher,
  aabPath,
  packageName,
  track,
  expectedVersionCode,
  versionName,
  releaseName,
}) {
  const stat = regularAab(aabPath);
  const aabSha256 = await sha256File(aabPath);
  const expected = parseVersionCode(expectedVersionCode);
  let editId = "";
  let readbackEditId = "";
  let committed = false;

  try {
    const inserted = await androidpublisher.edits.insert({ packageName });
    editId = inserted.data?.id ?? "";
    if (!editId) throw new Error("Google Play did not return an edit id");

    const [bundleList, currentTrack] = await Promise.all([
      androidpublisher.edits.bundles.list({ packageName, editId }),
      getTrack(androidpublisher, packageName, editId, track),
    ]);
    const existingBundle = bundleVersionCodes(bundleList.data?.bundles).has(
      expected,
    );
    const plan = planTrackUpdate(currentTrack, expected, releaseName);

    let uploaded = false;
    if (!existingBundle) {
      const upload = await androidpublisher.edits.bundles.upload({
        packageName,
        editId,
        media: {
          mimeType: "application/octet-stream",
          body: createReadStream(aabPath),
        },
      });
      const uploadedVersionCode = parseVersionCode(upload.data?.versionCode);
      if (uploadedVersionCode !== expected) {
        throw new Error(
          `Google Play uploaded version code ${uploadedVersionCode}, expected ${expected}`,
        );
      }
      uploaded = true;
    }

    if (!plan.updateRequired) {
      await deleteEditQuietly(androidpublisher, packageName, editId);
      editId = "";
      const readback = assertCommittedTrack(currentTrack, expected);
      return {
        schemaVersion: 1,
        packageName,
        track,
        versionCode: expected,
        versionName,
        action: "already_current",
        uploaded: false,
        committed: false,
        priorVersionCodes: plan.priorVersionCodes,
        readback,
        aab: {
          fileName: basename(aabPath),
          sizeBytes: stat.size,
          sha256: aabSha256,
        },
      };
    }

    await androidpublisher.edits.tracks.update({
      packageName,
      editId,
      track,
      requestBody: plan.requestBody,
    });
    await androidpublisher.edits.commit({ packageName, editId });
    committed = true;
    editId = "";

    const readbackEdit = await androidpublisher.edits.insert({ packageName });
    readbackEditId = readbackEdit.data?.id ?? "";
    if (!readbackEditId)
      throw new Error("Google Play did not return a readback edit id");
    const committedTrack = await getTrack(
      androidpublisher,
      packageName,
      readbackEditId,
      track,
    );
    const readback = assertCommittedTrack(committedTrack, expected);
    await deleteEditQuietly(androidpublisher, packageName, readbackEditId);
    readbackEditId = "";

    return {
      schemaVersion: 1,
      packageName,
      track,
      versionCode: expected,
      versionName,
      action: uploaded ? "uploaded_and_committed" : "existing_bundle_committed",
      uploaded,
      committed,
      priorVersionCodes: plan.priorVersionCodes,
      readback,
      aab: {
        fileName: basename(aabPath),
        sizeBytes: stat.size,
        sha256: aabSha256,
      },
    };
  } finally {
    await deleteEditQuietly(androidpublisher, packageName, editId);
    await deleteEditQuietly(androidpublisher, packageName, readbackEditId);
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const androidpublisher = await createAndroidPublisher();
  const receipt = await publishInternalRelease({
    androidpublisher,
    aabPath: options.aabPath,
    packageName: options.packageName,
    track: options.track,
    expectedVersionCode: options.expectedVersionCode,
    versionName: options.versionName,
    releaseName: options.releaseName,
  });
  const rendered = `${JSON.stringify(receipt, null, 2)}\n`;
  if (options.receiptPath)
    writeFileSync(options.receiptPath, rendered, { mode: 0o600 });
  if (options.json || !options.receiptPath) process.stdout.write(rendered);
  else {
    console.log(
      `Google Play ${receipt.track}: ${receipt.action}; versionCode=${receipt.versionCode}; sha256=${receipt.aab.sha256}`,
    );
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(googleErrorSummary(error));
    process.exit(1);
  });
}
