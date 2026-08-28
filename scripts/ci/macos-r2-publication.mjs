#!/usr/bin/env node

import {
  createHash,
  createPublicKey,
  verify as verifySignature,
} from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

import {
  DOMAIN_CORE_REPOSITORY,
  exactObject,
  regularFile,
  safeAssetName,
} from "../lib/domain-core-release-evidence.mjs";
import {
  validatePromotionReceipt,
  validateRollbackTargetReceipt,
  verifyChecksums,
  verifyUpdateMetadata,
} from "./promote-github-release.mjs";

const COMMIT = /^[0-9a-f]{40}$/u;
const VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const MANIFEST_SCHEMA_VERSION = 1;
const ROLLBACK_MANIFEST_KIND = "macos-appcast-rollback";
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const APP_BUNDLE_NAME = "OpenBurnBar.app";
const APP_INFO_PLIST = `${APP_BUNDLE_NAME}/Contents/Info.plist`;
const ZIP_EXTRACTION_SCRIPT = String.raw`
import os
import shutil
import stat
import sys
import unicodedata
import zipfile

archive, destination = sys.argv[1:]
max_entries = 100_000
max_file_bytes = 1 * 1024 * 1024 * 1024
max_total_bytes = 2 * 1024 * 1024 * 1024
# Comfortably above PATH_MAX on both macOS (1024) and Linux (4096).
max_symlink_target_bytes = 4096

with zipfile.ZipFile(archive) as source:
    entries = source.infolist()
    if not entries or len(entries) > max_entries:
        raise ValueError("archive has an invalid entry count")

    seen = set()
    seen_filesystem_names = set()
    symlink_paths = set()
    total_bytes = 0
    info_plists = 0
    for entry in entries:
        name = entry.filename
        if (
            not name
            or "\x00" in name
            or "\\" in name
            or name.startswith("/")
            or unicodedata.normalize("NFC", name) != name
        ):
            raise ValueError("archive contains an unsafe or non-canonical path")
        is_directory = name.endswith("/")
        path = name[:-1] if is_directory else name
        parts = path.split("/")
        if (
            not path
            or any(part in ("", ".", "..") for part in parts)
            or parts[0] != "OpenBurnBar.app"
            or (len(parts) == 1 and not is_directory)
        ):
            raise ValueError("archive must contain only the canonical root OpenBurnBar.app")
        filesystem_name = unicodedata.normalize("NFC", path).casefold()
        if path in seen or filesystem_name in seen_filesystem_names:
            raise ValueError("archive contains duplicate or filesystem-colliding paths")
        seen.add(path)
        seen_filesystem_names.add(filesystem_name)
        if entry.flag_bits & 0x1:
            raise ValueError("archive contains an encrypted entry")

        unix_mode = (entry.external_attr >> 16) & 0xFFFF
        if entry.create_system == 3 and unix_mode:
            entry_type = stat.S_IFMT(unix_mode)
            if entry_type == stat.S_IFLNK:
                # A signed macOS bundle cannot be represented without symlinks:
                # every versioned framework carries Versions/Current -> A plus
                # the Resources/Headers aliases beside it, and codesign seals
                # them. Rejecting the type outright meant no real app could ever
                # pass -- this release ships GLTFKit2.framework. Reject the
                # dangerous shape instead: the link target must be relative and
                # must resolve inside the bundle root (zip-slip), which is the
                # property this check was reaching for.
                if is_directory:
                    raise ValueError("archive contains a symlink marked as a directory")
                # Read the target only after bounding it. A symlink entry is a
                # short path, but a crafted one can be a highly compressed
                # oversized member, and read() would decompress all of it here --
                # before the per-entry and total-size checks below.
                if entry.file_size > max_symlink_target_bytes:
                    raise ValueError("archive contains an oversized symlink target")
                target = source.read(entry).decode("utf-8", "strict")
                if (
                    not target
                    or "\x00" in target
                    or target.startswith("/")
                    or "\\" in target
                ):
                    raise ValueError("archive contains an unsafe symlink target")
                resolved = os.path.normpath(
                    os.path.join(os.path.dirname(path), target)
                )
                if (
                    resolved != "OpenBurnBar.app"
                    and not resolved.startswith("OpenBurnBar.app/")
                ):
                    raise ValueError("archive symlink escapes the bundle root")
                symlink_paths.add(path)
            elif is_directory:
                if entry_type != stat.S_IFDIR:
                    raise ValueError("archive directory has an invalid file type")
            elif entry_type not in (0, stat.S_IFREG):
                raise ValueError("archive contains a non-regular file")

        if entry.file_size < 0 or entry.file_size > max_file_bytes:
            raise ValueError("archive entry exceeds the extraction size limit")
        total_bytes += entry.file_size
        if total_bytes > max_total_bytes:
            raise ValueError("archive exceeds the extraction size limit")
        if path == "OpenBurnBar.app/Contents/Info.plist":
            if is_directory:
                raise ValueError("app Info.plist must be a regular file")
            info_plists += 1

    if info_plists != 1:
        raise ValueError("archive must contain exactly one canonical app Info.plist")

    # The per-entry target check above is lexical, so it cannot see a chain: with
    # aliases such as "a -> ." and "a/b -> ." a later target of "../../../../tmp"
    # normalizes inside the bundle by name while physically resolving outside it,
    # and an entry beneath that link then lands outside the extraction tree.
    # In a real signed bundle every symlink is a leaf -- Versions/Current and the
    # aliases beside it are never archived through -- so requiring that no path
    # descends through one costs nothing and makes chains impossible to express.
    for path in seen:
        parts = path.split("/")
        for index in range(1, len(parts)):
            if "/".join(parts[:index]) in symlink_paths:
                raise ValueError("archive path descends through a symlink")

    os.makedirs(destination, mode=0o700, exist_ok=False)
    real_destination = os.path.realpath(destination)

    def checked_parent(output):
        # Belt and braces for the ancestor rule above: resolve the parent for
        # real, so a link that slipped past the name-based checks still cannot
        # place a file outside the extraction tree.
        parent = os.path.dirname(output)
        os.makedirs(parent, mode=0o700, exist_ok=True)
        real_parent = os.path.realpath(parent)
        if real_parent != real_destination and not real_parent.startswith(
            real_destination + os.sep
        ):
            raise ValueError("archive entry escapes the extraction root")

    for entry in entries:
        name = entry.filename
        is_directory = name.endswith("/")
        path = name[:-1] if is_directory else name
        output = os.path.join(destination, *path.split("/"))
        unix_mode = (entry.external_attr >> 16) & 0xFFFF
        if is_directory:
            checked_parent(output)
            os.makedirs(output, mode=0o700, exist_ok=True)
            continue
        checked_parent(output)
        if entry.create_system == 3 and stat.S_IFMT(unix_mode) == stat.S_IFLNK:
            # Validated above as relative and bundle-internal. Recreate it as a
            # symlink rather than a regular file holding the target text, so the
            # extracted tree matches the signed bundle it is standing in for.
            os.symlink(source.read(entry).decode("utf-8", "strict"), output)
            continue
        with source.open(entry, "r") as input_file:
            with open(output, "xb") as output_file:
                shutil.copyfileobj(input_file, output_file, length=1024 * 1024)
        permissions = unix_mode & 0o777 if entry.create_system == 3 else 0o600
        os.chmod(output, permissions or 0o600)
`;
const PLIST_KEY_SCRIPT = String.raw`
import plistlib
import sys

with open(sys.argv[1], "rb") as plist_file:
    value = plistlib.load(plist_file).get("SUPublicEDKey")
if not isinstance(value, str) or not value.strip():
    raise ValueError("SUPublicEDKey is missing from the audited app Info.plist")
sys.stdout.write(value.strip())
`;

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function hashBytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function fileRecord(path) {
  const bytes = readFileSync(path);
  return {
    size: bytes.length,
    sha256: hashBytes(bytes),
  };
}

function verifyAppBundleCodeSignature(appBundlePath) {
  const injectedVerifier = process.env.OPENBURNBAR_TEST_CODESIGN_VERIFY_BIN;
  let command = "/usr/bin/codesign";
  let commandArguments = [
    "--verify",
    "--deep",
    "--strict",
    "--verbose=2",
    appBundlePath,
  ];
  if (injectedVerifier !== undefined) {
    if (
      process.env.NODE_ENV !== "test" ||
      process.env.NODE_TEST_CONTEXT === undefined
    ) {
      throw new Error(
        "test code-signature verifier injection is only allowed under node:test",
      );
    }
    command = regularFile(
      resolve(injectedVerifier),
      "test code-signature verifier",
    );
    commandArguments = [appBundlePath];
  }
  const verification = spawnSync(command, commandArguments, {
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (verification.status !== 0) {
    const detail =
      verification.error?.message ??
      verification.stderr?.trim() ??
      `exit ${String(verification.status)}`;
    throw new Error(
      `audited OpenBurnBar.app does not have a valid code signature: ${detail}`,
    );
  }
}

function candidateSparklePublicKeyBase64(
  update,
  downloads,
  verifyAppSignature,
) {
  const zipPath = regularFile(
    downloads.get(update.latest.zip),
    "audited macOS app ZIP",
  );
  const extractionRoot = mkdtempSync(join(tmpdir(), "openburnbar-signed-app-"));
  const extractedDirectory = join(extractionRoot, "archive");
  try {
    const extraction = spawnSync(
      "python3",
      ["-c", ZIP_EXTRACTION_SCRIPT, zipPath, extractedDirectory],
      {
        encoding: "utf8",
        maxBuffer: 4 * 1024 * 1024,
      },
    );
    if (extraction.status !== 0) {
      const detail =
        extraction.error?.message ??
        extraction.stderr?.trim() ??
        `exit ${String(extraction.status)}`;
      throw new Error(`audited macOS app ZIP is unsafe: ${detail}`);
    }
    const infoPlist = regularFile(
      join(extractedDirectory, APP_INFO_PLIST),
      "audited app Info.plist",
    );
    const beforeVerification = fileRecord(infoPlist);
    verifyAppSignature(resolve(extractedDirectory, APP_BUNDLE_NAME));
    const afterVerification = fileRecord(infoPlist);
    if (
      beforeVerification.size !== afterVerification.size ||
      beforeVerification.sha256 !== afterVerification.sha256
    ) {
      throw new Error(
        "audited app Info.plist changed during code-signature verification",
      );
    }
    const keyRead = spawnSync("python3", ["-c", PLIST_KEY_SCRIPT, infoPlist], {
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
    });
    if (keyRead.status !== 0) {
      const detail =
        keyRead.error?.message ??
        keyRead.stderr?.trim() ??
        `exit ${String(keyRead.status)}`;
      throw new Error(`could not read audited app SUPublicEDKey: ${detail}`);
    }
    const afterKeyRead = fileRecord(infoPlist);
    if (
      afterVerification.size !== afterKeyRead.size ||
      afterVerification.sha256 !== afterKeyRead.sha256
    ) {
      throw new Error("audited app Info.plist changed while reading its key");
    }
    return keyRead.stdout.trim();
  } finally {
    rmSync(extractionRoot, { recursive: true, force: true });
  }
}

function verifySparkleDmgSignature(
  update,
  downloads,
  verifyAppSignature = verifyAppBundleCodeSignature,
) {
  const publicKeyBase64 = candidateSparklePublicKeyBase64(
    update,
    downloads,
    verifyAppSignature,
  );
  const rawPublicKey = Buffer.from(publicKeyBase64, "base64");
  if (
    rawPublicKey.length !== 32 ||
    rawPublicKey.toString("base64") !== publicKeyBase64
  ) {
    throw new Error("pinned SUPublicEDKey must be a canonical raw Ed25519 key");
  }
  const signature = Buffer.from(update.latest.sparkleEdSignature, "base64");
  const dmg = readFileSync(
    regularFile(downloads.get(update.latest.dmg), "audited Sparkle DMG"),
  );
  const publicKey = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, rawPublicKey]),
    format: "der",
    type: "spki",
  });
  if (!verifySignature(null, dmg, publicKey, signature)) {
    throw new Error(
      "audited DMG does not verify against the app's pinned SUPublicEDKey",
    );
  }
}

function canonicalBaseUrl(value, label) {
  let url;
  try {
    url = new URL(value);
  } catch (error) {
    throw new Error(`${label} must be a valid URL: ${error.message}`);
  }
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new Error(`${label} must be a credential-free HTTPS base URL`);
  }
  url.pathname = url.pathname.replace(/\/+$/u, "");
  return url.toString().replace(/\/$/u, "");
}

function contentType(name) {
  if (name.endsWith(".dmg")) return "application/x-apple-diskimage";
  if (name.endsWith(".tar.gz")) return "application/gzip";
  if (name.endsWith(".zip")) return "application/zip";
  if (name.endsWith(".xml")) return "application/xml; charset=utf-8";
  if (name.endsWith(".txt") || name.endsWith(".sha256")) {
    return "text/plain; charset=utf-8";
  }
  if (name.endsWith(".json")) return "application/json; charset=utf-8";
  return "application/octet-stream";
}

function publicationNames(version) {
  const source = `OpenBurnBar-${version}-corresponding-source.tar.gz`;
  return {
    immutable: [
      `OpenBurnBar-${version}-macOS.dmg`,
      `OpenBurnBar-${version}-macOS.zip`,
      `checksums-v${version}.txt`,
      `sbom-v${version}.spdx.json`,
      source,
      `${source}.sha256`,
    ],
    metadata: ["release-metadata.json"],
    discovery: ["latest-macos.json", "appcast.xml"],
  };
}

function validateCoordinates({ version, tag, commit }) {
  if (typeof version !== "string" || !VERSION.test(version)) {
    throw new Error("R2 publication version must be stable canonical SemVer");
  }
  if (tag !== `v${version}`) {
    throw new Error("R2 publication tag must exactly match the version");
  }
  if (typeof commit !== "string" || !COMMIT.test(commit)) {
    throw new Error("R2 publication commit must be a full lowercase Git SHA");
  }
}

function receiptAssetMap(receipt) {
  return new Map(receipt.identity.assets.map((asset) => [asset.name, asset]));
}

function verifyReceiptDirectory(assetDirectory, receipt) {
  const directory = resolve(assetDirectory);
  const downloads = new Map();
  for (const asset of receipt.identity.assets) {
    const path = regularFile(
      join(directory, safeAssetName(asset.name, "release receipt asset name")),
      `release receipt asset ${asset.name}`,
    );
    const record = fileRecord(path);
    if (
      record.size !== asset.size ||
      `sha256:${record.sha256}` !== asset.digest
    ) {
      throw new Error(
        `release receipt asset ${asset.name} does not match its audited size and digest`,
      );
    }
    downloads.set(asset.name, path);
  }
  return downloads;
}

function publicationEntry(name, downloads, receiptAssets, cacheControl) {
  const path = downloads.get(name);
  const receiptAsset = receiptAssets.get(name);
  if (!path || !receiptAsset) {
    throw new Error(
      `required audited R2 publication asset is missing: ${name}`,
    );
  }
  const record = fileRecord(path);
  return {
    name,
    path,
    size: record.size,
    sha256: record.sha256,
    contentType: contentType(name),
    cacheControl,
  };
}

export function preflightR2Publication({
  assetDirectory,
  receiptPath,
  version,
  tag,
  commit,
  publicBaseUrl,
  verifyAppSignature = verifyAppBundleCodeSignature,
}) {
  validateCoordinates({ version, tag, commit });
  const receipt = validatePromotionReceipt(
    parseJson(
      readFileSync(
        regularFile(resolve(receiptPath), "release promotion receipt"),
        "utf8",
      ),
      "release promotion receipt",
    ),
  );
  if (
    receipt.repository !== DOMAIN_CORE_REPOSITORY ||
    receipt.version !== version ||
    receipt.tag !== tag ||
    receipt.commit !== commit
  ) {
    throw new Error(
      "release promotion receipt does not bind the requested R2 candidate",
    );
  }

  const downloads = verifyReceiptDirectory(assetDirectory, receipt);
  const receiptAssets = receiptAssetMap(receipt);
  verifyChecksums(version, downloads);
  const update = verifyUpdateMetadata(
    {
      version,
      tag,
      commit,
      domainCoreProfile: receipt.domainCoreProfile,
    },
    downloads,
  );
  verifySparkleDmgSignature(update, downloads, verifyAppSignature);
  const targetBaseUrl = canonicalBaseUrl(
    publicBaseUrl,
    "R2 public verification base URL",
  );
  if (
    canonicalBaseUrl(
      update.metadata.updateBaseUrl,
      "audited release updateBaseUrl",
    ) !== targetBaseUrl
  ) {
    throw new Error(
      "audited release updateBaseUrl must exactly match the requested R2 public base URL",
    );
  }
  const names = publicationNames(version);
  const immutableCache = "public, max-age=31536000, immutable";
  const metadataCache = "public, max-age=300";
  const manifest = {
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    repository: DOMAIN_CORE_REPOSITORY,
    version,
    tag,
    commit,
    publicBaseUrl: targetBaseUrl,
    releaseIdentity: receipt.identity,
    expected: {
      dmg: update.latest.dmg,
      zip: update.latest.zip,
      correspondingSource: update.latest.correspondingSource,
      length: update.latest.length,
      sha256: update.latest.sha256,
      sparkleEdSignature: update.latest.sparkleEdSignature,
      updateBaseUrl: targetBaseUrl,
    },
    groups: {
      immutable: names.immutable.map((name) =>
        publicationEntry(name, downloads, receiptAssets, immutableCache),
      ),
      metadata: names.metadata.map((name) =>
        publicationEntry(name, downloads, receiptAssets, metadataCache),
      ),
      discovery: names.discovery.map((name) =>
        publicationEntry(name, downloads, receiptAssets, metadataCache),
      ),
    },
  };
  return manifest;
}

function assertRollbackTargetIsLatest(appcast, version) {
  const firstItem = appcast.match(/<item\b[\s\S]*?<\/item>/u)?.[0] ?? "";
  if (
    !firstItem.includes(
      `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
    )
  ) {
    throw new Error(
      `rolled-back appcast must advertise ${version} in its first item`,
    );
  }
}

export function preflightR2RollbackPublication({
  assetDirectory,
  receiptPath,
  appcastPath,
  derivedDirectory,
  version,
  tag,
  commit,
  publicBaseUrl,
  verifyAppSignature = verifyAppBundleCodeSignature,
}) {
  validateCoordinates({ version, tag, commit });
  const receiptFile = regularFile(
    resolve(receiptPath),
    "rollback target receipt",
  );
  const rawReceipt = parseJson(
    readFileSync(receiptFile, "utf8"),
    "rollback target receipt",
  );
  let authority;
  if (rawReceipt.kind === "macos-rollback-target") {
    const receipt = validateRollbackTargetReceipt(rawReceipt);
    if (
      receipt.repository !== DOMAIN_CORE_REPOSITORY ||
      receipt.version !== version ||
      receipt.tag !== tag ||
      receipt.commit !== commit
    ) {
      throw new Error(
        "rollback target receipt does not bind the requested R2 candidate",
      );
    }
    const downloads = verifyReceiptDirectory(assetDirectory, receipt);
    verifyChecksums(version, downloads, { includeRollback: false });
    const update = verifyUpdateMetadata({ version, tag, commit }, downloads, {
      verifyIosReceipt: false,
    });
    verifySparkleDmgSignature(update, downloads, verifyAppSignature);
    authority = {
      publicBaseUrl: canonicalBaseUrl(
        publicBaseUrl,
        "R2 public verification base URL",
      ),
      releaseIdentity: receipt.identity,
      downloads,
      update,
      expected: {
        dmg: update.latest.dmg,
        zip: update.latest.zip,
        correspondingSource: update.latest.correspondingSource,
        length: update.latest.length,
        sha256: update.latest.sha256,
        sparkleEdSignature: update.latest.sparkleEdSignature,
        updateBaseUrl: update.metadata.updateBaseUrl,
      },
    };
  } else {
    const releaseManifest = preflightR2Publication({
      assetDirectory,
      receiptPath,
      version,
      tag,
      commit,
      publicBaseUrl,
      verifyAppSignature,
    });
    const downloads = new Map(
      allEntries(releaseManifest).map((entry) => [entry.name, entry.path]),
    );
    authority = {
      publicBaseUrl: releaseManifest.publicBaseUrl,
      releaseIdentity: releaseManifest.releaseIdentity,
      downloads,
      update: verifyUpdateMetadata({ version, tag, commit }, downloads, {
        verifyIosReceipt: false,
      }),
      expected: releaseManifest.expected,
    };
  }
  const resolvedAppcast = regularFile(
    resolve(appcastPath),
    "rolled-back appcast",
  );
  if (basename(resolvedAppcast) !== "appcast.xml") {
    throw new Error("rolled-back appcast must be named appcast.xml");
  }

  const auditedDownloads = authority.downloads;
  const auditedUpdate = authority.update;
  const auditedAppcast = readFileSync(
    regularFile(
      auditedDownloads.get("appcast.xml"),
      "audited rollback appcast",
    ),
  );
  const requestedAppcast = readFileSync(resolvedAppcast);
  if (!requestedAppcast.equals(auditedAppcast)) {
    throw new Error(
      "rollback appcast must exactly match the audited target release appcast",
    );
  }
  const derived = resolve(derivedDirectory);
  mkdirSync(derived, { recursive: true });
  const rollbackBaseUrl = canonicalBaseUrl(
    authority.publicBaseUrl,
    "R2 rollback public base URL",
  );
  if (
    canonicalBaseUrl(
      auditedUpdate.metadata.updateBaseUrl,
      "audited rollback updateBaseUrl",
    ) !== rollbackBaseUrl
  ) {
    throw new Error(
      "audited rollback updateBaseUrl must exactly match the requested R2 public base URL",
    );
  }
  const latestBytes = readFileSync(auditedDownloads.get("latest-macos.json"));
  const metadataBytes = readFileSync(
    auditedDownloads.get("release-metadata.json"),
  );
  const appcastBytes = requestedAppcast;
  const derivedPaths = {
    appcast: join(derived, "appcast.xml"),
    latest: join(derived, "latest-macos.json"),
    metadata: join(derived, "release-metadata.json"),
  };
  writeFileSync(derivedPaths.appcast, appcastBytes, { mode: 0o600 });
  writeFileSync(derivedPaths.latest, latestBytes, { mode: 0o600 });
  writeFileSync(derivedPaths.metadata, metadataBytes, { mode: 0o600 });

  const downloads = new Map(auditedDownloads);
  downloads.set("appcast.xml", derivedPaths.appcast);
  downloads.set("latest-macos.json", derivedPaths.latest);
  downloads.set("release-metadata.json", derivedPaths.metadata);
  assertRollbackTargetIsLatest(appcastBytes.toString("utf8"), version);
  const update = verifyUpdateMetadata({ version, tag, commit }, downloads, {
    verifyIosReceipt: false,
  });

  const cacheControl = "public, max-age=300";
  const derivedEntry = (name, path) => {
    const record = fileRecord(path);
    return {
      name,
      path,
      size: record.size,
      sha256: record.sha256,
      contentType: contentType(name),
      cacheControl,
    };
  };
  return {
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    kind: ROLLBACK_MANIFEST_KIND,
    repository: DOMAIN_CORE_REPOSITORY,
    version,
    tag,
    commit,
    publicBaseUrl: authority.publicBaseUrl,
    releaseIdentity: authority.releaseIdentity,
    expected: {
      ...authority.expected,
      updateBaseUrl: update.metadata.updateBaseUrl,
    },
    groups: {
      metadata: [derivedEntry("release-metadata.json", derivedPaths.metadata)],
      discovery: [
        derivedEntry("latest-macos.json", derivedPaths.latest),
        derivedEntry("appcast.xml", derivedPaths.appcast),
      ],
    },
    verifyOnly: [
      publicationEntry(
        authority.expected.dmg,
        auditedDownloads,
        receiptAssetMap({ identity: authority.releaseIdentity }),
        "public, max-age=31536000, immutable",
      ),
      publicationEntry(
        authority.expected.zip,
        auditedDownloads,
        receiptAssetMap({ identity: authority.releaseIdentity }),
        "public, max-age=31536000, immutable",
      ),
      publicationEntry(
        authority.expected.correspondingSource,
        auditedDownloads,
        receiptAssetMap({ identity: authority.releaseIdentity }),
        "public, max-age=31536000, immutable",
      ),
    ],
  };
}

function validatePublicationEntry(raw, label) {
  const value = exactObject(
    raw,
    ["name", "path", "size", "sha256", "contentType", "cacheControl"],
    label,
  );
  safeAssetName(value.name, `${label} name`);
  regularFile(value.path, `${label} path`);
  if (
    !Number.isSafeInteger(value.size) ||
    value.size <= 0 ||
    typeof value.sha256 !== "string" ||
    !/^[0-9a-f]{64}$/u.test(value.sha256) ||
    typeof value.contentType !== "string" ||
    value.contentType === "" ||
    typeof value.cacheControl !== "string" ||
    value.cacheControl === ""
  ) {
    throw new Error(`${label} has invalid publication metadata`);
  }
  const record = fileRecord(value.path);
  if (record.size !== value.size || record.sha256 !== value.sha256) {
    throw new Error(`${label} changed after R2 publication preflight`);
  }
  return value;
}

function validateReleaseIdentity(raw) {
  const value = exactObject(
    raw,
    ["releaseID", "assets"],
    "R2 publication release identity",
  );
  if (
    !Number.isSafeInteger(value.releaseID) ||
    value.releaseID <= 0 ||
    !Array.isArray(value.assets)
  ) {
    throw new Error("R2 publication release identity is invalid");
  }
  const assets = value.assets.map((rawAsset, index) => {
    const asset = exactObject(
      rawAsset,
      ["id", "name", "size", "digest"],
      `R2 publication release identity assets[${index}]`,
    );
    safeAssetName(asset.name, `release identity assets[${index}] name`);
    if (
      !Number.isSafeInteger(asset.id) ||
      asset.id <= 0 ||
      !Number.isSafeInteger(asset.size) ||
      asset.size < 0 ||
      typeof asset.digest !== "string" ||
      !/^sha256:[0-9a-f]{64}$/u.test(asset.digest)
    ) {
      throw new Error(
        `R2 publication release identity assets[${index}] is invalid`,
      );
    }
    return asset;
  });
  if (
    new Set(assets.map((asset) => asset.name)).size !== assets.length ||
    JSON.stringify(assets) !==
      JSON.stringify(
        [...assets].sort((left, right) => left.name.localeCompare(right.name)),
      )
  ) {
    throw new Error(
      "R2 publication release identity assets must be unique and sorted",
    );
  }
  return new Map(assets.map((asset) => [asset.name, asset]));
}

function validateExpected(raw, version) {
  const value = exactObject(
    raw,
    [
      "dmg",
      "zip",
      "correspondingSource",
      "length",
      "sha256",
      "sparkleEdSignature",
      "updateBaseUrl",
    ],
    "R2 publication expected release",
  );
  const signature =
    typeof value.sparkleEdSignature === "string"
      ? Buffer.from(value.sparkleEdSignature, "base64")
      : Buffer.alloc(0);
  if (
    value.dmg !== `OpenBurnBar-${version}-macOS.dmg` ||
    value.zip !== `OpenBurnBar-${version}-macOS.zip` ||
    value.correspondingSource !==
      `OpenBurnBar-${version}-corresponding-source.tar.gz` ||
    !Number.isSafeInteger(value.length) ||
    value.length <= 0 ||
    typeof value.sha256 !== "string" ||
    !/^[0-9a-f]{64}$/u.test(value.sha256) ||
    signature.length !== 64 ||
    signature.toString("base64") !== value.sparkleEdSignature
  ) {
    throw new Error("R2 publication expected release identity is invalid");
  }
  value.updateBaseUrl = canonicalBaseUrl(
    value.updateBaseUrl,
    "R2 publication expected updateBaseUrl",
  );
  return value;
}

export function validateR2PublicationManifest(raw) {
  const value = exactObject(
    raw,
    [
      "schemaVersion",
      "repository",
      "version",
      "tag",
      "commit",
      "publicBaseUrl",
      "releaseIdentity",
      "expected",
      "groups",
    ],
    "R2 publication manifest",
  );
  validateCoordinates(value);
  if (
    value.schemaVersion !== MANIFEST_SCHEMA_VERSION ||
    value.repository !== DOMAIN_CORE_REPOSITORY
  ) {
    throw new Error("R2 publication manifest identity is invalid");
  }
  value.publicBaseUrl = canonicalBaseUrl(
    value.publicBaseUrl,
    "R2 publication manifest publicBaseUrl",
  );
  const releaseAssets = validateReleaseIdentity(value.releaseIdentity);
  value.expected = validateExpected(value.expected, value.version);
  const groups = exactObject(
    value.groups,
    ["immutable", "metadata", "discovery"],
    "R2 publication manifest groups",
  );
  const expectedNames = publicationNames(value.version);
  for (const groupName of ["immutable", "metadata", "discovery"]) {
    if (!Array.isArray(groups[groupName])) {
      throw new Error(`R2 publication group ${groupName} must be an array`);
    }
    groups[groupName] = groups[groupName].map((entry, index) =>
      validatePublicationEntry(entry, `R2 publication ${groupName}[${index}]`),
    );
    const actual = groups[groupName].map((entry) => entry.name);
    if (JSON.stringify(actual) !== JSON.stringify(expectedNames[groupName])) {
      throw new Error(
        `R2 publication group ${groupName} has an invalid ordered asset set`,
      );
    }
    for (const entry of groups[groupName]) {
      const releaseAsset = releaseAssets.get(entry.name);
      if (
        !releaseAsset ||
        releaseAsset.size !== entry.size ||
        releaseAsset.digest !== `sha256:${entry.sha256}`
      ) {
        throw new Error(
          `R2 publication ${entry.name} does not match the audited release identity`,
        );
      }
    }
  }
  const dmgEntry = groups.immutable.find(
    (entry) => entry.name === value.expected.dmg,
  );
  if (
    !dmgEntry ||
    dmgEntry.size !== value.expected.length ||
    dmgEntry.sha256 !== value.expected.sha256
  ) {
    throw new Error(
      "R2 publication expected DMG does not match its immutable asset entry",
    );
  }
  return value;
}

export function validateR2RollbackPublicationManifest(raw) {
  const value = exactObject(
    raw,
    [
      "schemaVersion",
      "kind",
      "repository",
      "version",
      "tag",
      "commit",
      "publicBaseUrl",
      "releaseIdentity",
      "expected",
      "groups",
      "verifyOnly",
    ],
    "R2 rollback publication manifest",
  );
  validateCoordinates(value);
  if (
    value.schemaVersion !== MANIFEST_SCHEMA_VERSION ||
    value.kind !== ROLLBACK_MANIFEST_KIND ||
    value.repository !== DOMAIN_CORE_REPOSITORY
  ) {
    throw new Error("R2 rollback publication manifest identity is invalid");
  }
  value.publicBaseUrl = canonicalBaseUrl(
    value.publicBaseUrl,
    "R2 rollback publication manifest publicBaseUrl",
  );
  const releaseAssets = validateReleaseIdentity(value.releaseIdentity);
  value.expected = validateExpected(value.expected, value.version);
  const groups = exactObject(
    value.groups,
    ["metadata", "discovery"],
    "R2 rollback publication manifest groups",
  );
  const expectedNames = {
    metadata: ["release-metadata.json"],
    discovery: ["latest-macos.json", "appcast.xml"],
  };
  for (const groupName of ["metadata", "discovery"]) {
    if (!Array.isArray(groups[groupName])) {
      throw new Error(
        `R2 rollback publication group ${groupName} must be an array`,
      );
    }
    groups[groupName] = groups[groupName].map((entry, index) =>
      validatePublicationEntry(
        entry,
        `R2 rollback publication ${groupName}[${index}]`,
      ),
    );
    if (
      JSON.stringify(groups[groupName].map((entry) => entry.name)) !==
      JSON.stringify(expectedNames[groupName])
    ) {
      throw new Error(
        `R2 rollback publication group ${groupName} has an invalid ordered asset set`,
      );
    }
  }
  if (!Array.isArray(value.verifyOnly) || value.verifyOnly.length !== 3) {
    throw new Error(
      "R2 rollback publication must verify the immutable DMG, app ZIP, and corresponding source",
    );
  }
  value.verifyOnly = value.verifyOnly.map((entry, index) =>
    validatePublicationEntry(
      entry,
      `R2 rollback publication verifyOnly[${index}]`,
    ),
  );
  if (
    JSON.stringify(value.verifyOnly.map((entry) => entry.name)) !==
    JSON.stringify([
      value.expected.dmg,
      value.expected.zip,
      value.expected.correspondingSource,
    ])
  ) {
    throw new Error("R2 rollback publication immutable assets are invalid");
  }

  for (const entry of value.verifyOnly) {
    const releaseAsset = releaseAssets.get(entry.name);
    if (
      !releaseAsset ||
      releaseAsset.size !== entry.size ||
      releaseAsset.digest !== `sha256:${entry.sha256}`
    ) {
      throw new Error(
        `R2 rollback publication ${entry.name} does not match the audited release identity`,
      );
    }
  }
  if (
    value.verifyOnly[0].size !== value.expected.length ||
    value.verifyOnly[0].sha256 !== value.expected.sha256
  ) {
    throw new Error(
      "R2 rollback publication expected DMG does not match its immutable asset entry",
    );
  }

  const downloads = new Map(
    [...groups.metadata, ...groups.discovery, ...value.verifyOnly].map(
      (entry) => [entry.name, entry.path],
    ),
  );
  const appcast = readFileSync(downloads.get("appcast.xml"), "utf8");
  assertRollbackTargetIsLatest(appcast, value.version);
  verifyUpdateMetadata(value, downloads, { verifyIosReceipt: false });
  return value;
}

export function sealR2PublicationManifest(rawManifest, sealedDirectory) {
  const manifest = validateR2PublicationManifest(rawManifest);
  const directory = resolve(sealedDirectory);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const sealed = structuredClone(manifest);

  for (const groupName of ["immutable", "metadata", "discovery"]) {
    sealed.groups[groupName] = manifest.groups[groupName].map((entry) => {
      const bytes = readFileSync(entry.path);
      if (bytes.length !== entry.size || hashBytes(bytes) !== entry.sha256) {
        throw new Error(
          `R2 publication ${entry.name} changed while sealing audited inputs`,
        );
      }
      const destination = join(directory, entry.name);
      writeFileSync(destination, bytes, { flag: "wx", mode: 0o400 });
      return { ...entry, path: destination };
    });
  }

  return validateR2PublicationManifest(sealed);
}

function allEntries(manifest) {
  return [
    ...manifest.groups.immutable,
    ...manifest.groups.metadata,
    ...manifest.groups.discovery,
  ];
}

async function fetchExactAsset(fetchImpl, baseUrl, entry, attempt, commit) {
  const url = new URL(`${baseUrl}/${encodeURIComponent(entry.name)}`);
  url.searchParams.set(
    "openburnbar_verify",
    `${commit}-${attempt}-${Date.now()}`,
  );
  const response = await fetchImpl(url, {
    redirect: "follow",
    headers: {
      "cache-control": "no-cache, no-store, max-age=0",
      pragma: "no-cache",
    },
  });
  if (!response.ok) {
    await response.body?.cancel?.().catch(() => {});
    throw new Error(`${entry.name} returned HTTP ${response.status}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  const contentLength = response.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^\d+$/u.test(contentLength) ||
      Number.parseInt(contentLength, 10) !== bytes.length)
  ) {
    throw new Error(`${entry.name} returned an invalid Content-Length`);
  }
  if (bytes.length !== entry.size || hashBytes(bytes) !== entry.sha256) {
    throw new Error(
      `${entry.name} public bytes do not match the audited release asset`,
    );
  }
  return bytes;
}

export async function verifyPublicR2Publication(
  rawManifest,
  {
    fetchImpl = fetch,
    attempts = 10,
    delayMs = 15_000,
    delayImpl = delay,
    requestTimeoutMs = 30_000,
    verifyAppSignature = verifyAppBundleCodeSignature,
  } = {},
) {
  const manifest = validateR2PublicationManifest(rawManifest);
  if (!Number.isSafeInteger(attempts) || attempts < 1 || attempts > 30) {
    throw new Error("public verification attempts must be between 1 and 30");
  }
  if (!Number.isSafeInteger(delayMs) || delayMs < 0 || delayMs > 120_000) {
    throw new Error(
      "public verification delay must be between 0 and 120000 ms",
    );
  }
  if (
    !Number.isSafeInteger(requestTimeoutMs) ||
    requestTimeoutMs < 1 ||
    requestTimeoutMs > 120_000
  ) {
    throw new Error(
      "public verification request timeout must be between 1 and 120000 ms",
    );
  }

  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const directory = mkdtempSync(join(tmpdir(), "openburnbar-r2-verify-"));
    try {
      const downloads = new Map();
      for (const entry of allEntries(manifest)) {
        const bytes = await fetchExactAsset(
          (url, options) =>
            fetchImpl(url, {
              ...options,
              signal: AbortSignal.timeout(requestTimeoutMs),
            }),
          manifest.publicBaseUrl,
          entry,
          attempt,
          manifest.commit,
        );
        const path = join(directory, entry.name);
        writeFileSync(path, bytes, { mode: 0o600 });
        downloads.set(entry.name, path);
      }
      verifyChecksums(manifest.version, downloads, {
        includeRollback: false,
      });
      const update = verifyUpdateMetadata(
        {
          version: manifest.version,
          tag: manifest.tag,
          commit: manifest.commit,
        },
        downloads,
        { verifyIosReceipt: false },
      );
      verifySparkleDmgSignature(update, downloads, verifyAppSignature);
      if (
        update.latest.dmg !== manifest.expected.dmg ||
        update.latest.zip !== manifest.expected.zip ||
        update.latest.correspondingSource !==
          manifest.expected.correspondingSource ||
        update.latest.length !== manifest.expected.length ||
        update.latest.sha256 !== manifest.expected.sha256 ||
        update.latest.sparkleEdSignature !==
          manifest.expected.sparkleEdSignature ||
        update.metadata.updateBaseUrl !== manifest.expected.updateBaseUrl
      ) {
        throw new Error(
          "public update metadata changed after R2 publication preflight",
        );
      }
      return {
        verified: true,
        attempts: attempt,
        version: manifest.version,
        tag: manifest.tag,
        commit: manifest.commit,
        dmg: manifest.expected.dmg,
        length: manifest.expected.length,
        sha256: manifest.expected.sha256,
      };
    } catch (error) {
      lastError = error;
      if (attempt < attempts) await delayImpl(delayMs);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }
  throw new Error(
    `public R2 release verification failed after ${attempts} attempts: ${
      lastError instanceof Error ? lastError.message : String(lastError)
    }`,
  );
}

export async function verifyPublicR2RollbackPublication(
  rawManifest,
  {
    fetchImpl = fetch,
    attempts = 10,
    delayMs = 15_000,
    delayImpl = delay,
    requestTimeoutMs = 30_000,
    verifyAppSignature = verifyAppBundleCodeSignature,
  } = {},
) {
  const manifest = validateR2RollbackPublicationManifest(rawManifest);
  if (!Number.isSafeInteger(attempts) || attempts < 1 || attempts > 30) {
    throw new Error("public verification attempts must be between 1 and 30");
  }
  if (!Number.isSafeInteger(delayMs) || delayMs < 0 || delayMs > 120_000) {
    throw new Error(
      "public verification delay must be between 0 and 120000 ms",
    );
  }
  if (
    !Number.isSafeInteger(requestTimeoutMs) ||
    requestTimeoutMs < 1 ||
    requestTimeoutMs > 120_000
  ) {
    throw new Error(
      "public verification request timeout must be between 1 and 120000 ms",
    );
  }

  const entries = [
    ...manifest.groups.metadata,
    ...manifest.groups.discovery,
    ...manifest.verifyOnly,
  ];
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const directory = mkdtempSync(
      join(tmpdir(), "openburnbar-r2-rollback-verify-"),
    );
    try {
      const downloads = new Map();
      for (const entry of entries) {
        const bytes = await fetchExactAsset(
          (url, options) =>
            fetchImpl(url, {
              ...options,
              signal: AbortSignal.timeout(requestTimeoutMs),
            }),
          manifest.publicBaseUrl,
          entry,
          attempt,
          manifest.commit,
        );
        const path = join(directory, entry.name);
        writeFileSync(path, bytes, { mode: 0o600 });
        downloads.set(entry.name, path);
      }
      const appcast = readFileSync(downloads.get("appcast.xml"), "utf8");
      assertRollbackTargetIsLatest(appcast, manifest.version);
      const update = verifyUpdateMetadata(manifest, downloads, {
        verifyIosReceipt: false,
      });
      verifySparkleDmgSignature(update, downloads, verifyAppSignature);
      if (
        update.latest.dmg !== manifest.expected.dmg ||
        update.latest.length !== manifest.expected.length ||
        update.latest.sha256 !== manifest.expected.sha256 ||
        update.latest.sparkleEdSignature !==
          manifest.expected.sparkleEdSignature
      ) {
        throw new Error(
          "public rollback metadata changed after R2 publication preflight",
        );
      }
      return {
        verified: true,
        attempts: attempt,
        version: manifest.version,
        tag: manifest.tag,
        commit: manifest.commit,
        dmg: manifest.expected.dmg,
        length: manifest.expected.length,
        sha256: manifest.expected.sha256,
      };
    } catch (error) {
      lastError = error;
      if (attempt < attempts) await delayImpl(delayMs);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }
  throw new Error(
    `public R2 rollback verification failed after ${attempts} attempts: ${
      lastError instanceof Error ? lastError.message : String(lastError)
    }`,
  );
}

function parseArguments(argv) {
  const command = argv[0];
  const required =
    command === "preflight"
      ? [
          "--asset-dir",
          "--receipt",
          "--version",
          "--tag",
          "--commit",
          "--public-base-url",
          "--output",
        ]
      : command === "verify-public"
        ? ["--manifest", "--attempts", "--delay-ms", "--request-timeout-ms"]
        : command === "seal"
          ? ["--manifest", "--sealed-dir", "--output"]
          : command === "rollback-preflight"
            ? [
                "--asset-dir",
                "--receipt",
                "--appcast",
                "--derived-dir",
                "--version",
                "--tag",
                "--commit",
                "--public-base-url",
                "--output",
              ]
            : command === "verify-rollback-public"
              ? [
                  "--manifest",
                  "--attempts",
                  "--delay-ms",
                  "--request-timeout-ms",
                ]
              : null;
  if (!required || argv.length !== 1 + required.length * 2) {
    throw new Error(
      "usage: preflight --asset-dir DIR --receipt PATH --version VERSION --tag TAG --commit SHA --public-base-url URL --output PATH | seal --manifest PATH --sealed-dir DIR --output PATH | verify-public --manifest PATH --attempts N --delay-ms N --request-timeout-ms N | rollback-preflight --asset-dir DIR --receipt PATH --appcast PATH --derived-dir DIR --version VERSION --tag TAG --commit SHA --public-base-url URL --output PATH | verify-rollback-public --manifest PATH --attempts N --delay-ms N --request-timeout-ms N",
    );
  }
  const values = new Map();
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.includes(flag) || values.has(flag) || !value) {
      throw new Error(`invalid R2 publication argument: ${String(flag)}`);
    }
    values.set(flag, value);
  }
  return { command, values };
}

export async function run(argv) {
  const { command, values } = parseArguments(argv);
  if (command === "preflight" || command === "rollback-preflight") {
    const inputs = {
      assetDirectory: values.get("--asset-dir"),
      receiptPath: values.get("--receipt"),
      version: values.get("--version"),
      tag: values.get("--tag"),
      commit: values.get("--commit"),
      publicBaseUrl: values.get("--public-base-url"),
    };
    const manifest =
      command === "preflight"
        ? preflightR2Publication(inputs)
        : preflightR2RollbackPublication({
            ...inputs,
            appcastPath: values.get("--appcast"),
            derivedDirectory: values.get("--derived-dir"),
          });
    const output = resolve(values.get("--output"));
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    process.stdout.write(
      `${JSON.stringify({ ok: true, preflight: true, manifest: output })}\n`,
    );
    return manifest;
  }

  let manifest = parseJson(
    readFileSync(
      regularFile(resolve(values.get("--manifest")), "R2 publication manifest"),
      "utf8",
    ),
    "R2 publication manifest",
  );
  if (command === "seal") {
    manifest = sealR2PublicationManifest(manifest, values.get("--sealed-dir"));
    const output = resolve(values.get("--output"));
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    process.stdout.write(
      `${JSON.stringify({ ok: true, sealed: true, manifest: output })}\n`,
    );
    return manifest;
  }
  const options = {
    attempts: Number.parseInt(values.get("--attempts"), 10),
    delayMs: Number.parseInt(values.get("--delay-ms"), 10),
    requestTimeoutMs: Number.parseInt(values.get("--request-timeout-ms"), 10),
  };
  const result =
    command === "verify-public"
      ? await verifyPublicR2Publication(manifest, options)
      : await verifyPublicR2RollbackPublication(manifest, options);
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    await run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
