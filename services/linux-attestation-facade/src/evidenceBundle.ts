import { createPublicKey, verify } from "node:crypto";
import type { AttestationChallenge } from "./contracts.js";
import { PublicError } from "./errors.js";
import {
  exactKeys,
  integer,
  object,
  sha256,
  sha256Hex,
  string,
} from "./validation.js";

const MAGIC = Buffer.from("OBBATST1", "ascii");
const PREFIX_BYTES = 12;
const MAX_BUNDLE_BYTES = 16 * 1024 * 1024;
const KINDS = [
  "ima_ascii_runtime_measurements",
  "uefi_binary_bios_measurements",
  "installed_manifest",
  "installed_manifest_signature",
] as const;

export interface ParsedEvidenceBundle {
  imaLog: Buffer;
  uefiLog: Buffer;
  installedManifest: Buffer;
  installedManifestSignature: Buffer;
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const source = value as Record<string, unknown>;
  return `{${Object.keys(source)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalJson(source[key])}`)
    .join(",")}}`;
}

export function parseEvidenceBundle(bytes: Buffer): ParsedEvidenceBundle {
  if (
    bytes.byteLength > MAX_BUNDLE_BYTES ||
    bytes.byteLength < PREFIX_BYTES + 2 ||
    !bytes.subarray(0, 8).equals(MAGIC)
  )
    return invalidBundle();
  const headerLength = bytes.readUInt32BE(8);
  if (
    headerLength < 2 ||
    headerLength > 16_384 ||
    PREFIX_BYTES + headerLength >= bytes.byteLength
  )
    return invalidBundle();
  const headerBytes = bytes.subarray(PREFIX_BYTES, PREFIX_BYTES + headerLength);
  let text: string;
  let parsed: unknown;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(headerBytes);
    parsed = JSON.parse(text) as unknown;
  } catch {
    return invalidBundle();
  }
  const header = object(parsed, "evidence bundle header");
  exactKeys(header, ["schemaVersion", "records"], "evidence bundle header");
  if (
    header.schemaVersion !== 1 ||
    !Array.isArray(header.records) ||
    header.records.length !== 4
  )
    return invalidBundle();
  let expectedOffset = PREFIX_BYTES + headerLength;
  const bodies: Buffer[] = [];
  for (let index = 0; index < KINDS.length; index += 1) {
    const record = object(header.records[index], "evidence bundle record");
    exactKeys(
      record,
      ["kind", "offset", "byteLength", "sha256"],
      "evidence bundle record",
    );
    if (record.kind !== KINDS[index]) return invalidBundle();
    const offset = integer(
      record.offset,
      "record.offset",
      PREFIX_BYTES,
      MAX_BUNDLE_BYTES - 1,
    );
    const byteLength = integer(
      record.byteLength,
      "record.byteLength",
      1,
      MAX_BUNDLE_BYTES,
    );
    const digest = sha256Hex(record.sha256, "record.sha256");
    if (offset !== expectedOffset || offset + byteLength > bytes.byteLength)
      return invalidBundle();
    const body = bytes.subarray(offset, offset + byteLength);
    if (sha256(body) !== digest) return invalidBundle();
    bodies.push(body);
    expectedOffset += byteLength;
  }
  // Canonicalization is recursive, so run it only after the fixed shallow
  // header and every record field have been reduced to validated primitives.
  if (canonicalJson(parsed) !== text) return invalidBundle();
  if (expectedOffset !== bytes.byteLength) return invalidBundle();
  const [imaLog, uefiLog, installedManifest, installedManifestSignature] =
    bodies;
  if (
    imaLog === undefined ||
    uefiLog === undefined ||
    installedManifest === undefined ||
    installedManifestSignature === undefined
  )
    return invalidBundle();
  return { imaLog, uefiLog, installedManifest, installedManifestSignature };
}

export function verifyInstalledManifest(
  bundle: ParsedEvidenceBundle,
  challenge: AttestationChallenge,
  publicKeyPem: string,
): void {
  if (
    bundle.installedManifestSignature.byteLength !== 64 ||
    sha256(bundle.installedManifest) !== challenge.releaseDigestSha256
  )
    return invalidManifest();
  let key;
  try {
    key = createPublicKey(publicKeyPem);
    if (
      key.asymmetricKeyType !== "ed25519" ||
      !verify(
        null,
        bundle.installedManifest,
        key,
        bundle.installedManifestSignature,
      )
    )
      return invalidManifest();
  } catch {
    return invalidManifest();
  }
  let parsed: unknown;
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(
      bundle.installedManifest,
    );
    parsed = JSON.parse(text) as unknown;
  } catch {
    return invalidManifest();
  }
  if (`${canonicalJson(parsed)}\n` !== text) return invalidManifest();
  const manifest = object(parsed, "installed manifest");
  const required = [
    "schemaVersion",
    "product",
    "appId",
    "firebaseAppId",
    "packageVersion",
    "gitCommit",
    "packageArchitecture",
    "packageFormat",
    "packageName",
    "policyId",
    "brokerProtocolVersion",
    "installedFilesRootSha256",
    "authorizedClients",
    "files",
  ];
  exactKeys(manifest, required, "installed manifest");
  const authorizedClients = Array.isArray(manifest.authorizedClients)
    ? manifest.authorizedClients
    : [];
  const files = Array.isArray(manifest.files) ? manifest.files : [];
  const daemon = validateAuthorizedClients(authorizedClients);
  const filesRoot = validateFiles(files, daemon);
  const valid =
    manifest.schemaVersion === 1 &&
    manifest.product === "OpenBurnBar" &&
    manifest.appId === "dev.openburnbar.OpenBurnBar" &&
    /^1:[0-9]+:web:[A-Za-z0-9]+$/.test(
      string(manifest.firebaseAppId, "manifest.firebaseAppId", 160),
    ) &&
    manifest.firebaseAppId === challenge.appId &&
    /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(
      string(manifest.packageVersion, "manifest.packageVersion", 80),
    ) &&
    manifest.packageVersion === challenge.appVersion &&
    (manifest.packageArchitecture === "aarch64" ||
      manifest.packageArchitecture === "x86_64") &&
    manifest.packageArchitecture === challenge.architecture &&
    (manifest.packageFormat === "deb" || manifest.packageFormat === "rpm") &&
    manifest.packageName === "open-burn-bar" &&
    string(manifest.policyId, "manifest.policyId", 128) ===
      challenge.policyId &&
    manifest.brokerProtocolVersion === 2 &&
    /^[a-f0-9]{40}$/.test(String(manifest.gitCommit)) &&
    sha256Hex(
      manifest.installedFilesRootSha256,
      "manifest.installedFilesRootSha256",
    ) === filesRoot;
  if (!valid) return invalidManifest();
}

interface AuthorizedDaemon {
  path: string;
  sha256: string;
  ownerUid: number;
  ownerGid: number;
  mode: number;
}

function validateAuthorizedClients(values: unknown[]): AuthorizedDaemon {
  if (values.length !== 1) return invalidManifest();
  const value = object(values[0], "manifest.authorizedClients[0]");
  exactKeys(
    value,
    ["role", "path", "sha256", "ownerUid", "ownerGid", "mode"],
    "manifest.authorizedClients[0]",
  );
  const daemon: AuthorizedDaemon = {
    path: string(value.path, "authorized client path", 4096),
    sha256: sha256Hex(value.sha256, "authorized client sha256"),
    ownerUid: integer(value.ownerUid, "authorized client ownerUid", 0, 0),
    ownerGid: integer(value.ownerGid, "authorized client ownerGid", 0, 0),
    mode: integer(value.mode, "authorized client mode", 0o755, 0o755),
  };
  if (value.role !== "daemon" || daemon.path !== "/usr/bin/openburnbar-daemon")
    return invalidManifest();
  return daemon;
}

function validateFiles(values: unknown[], daemon: AuthorizedDaemon): string {
  if (values.length === 0 || values.length > 4096) return invalidManifest();
  const paths = new Set<string>();
  const rootRecords: string[] = [];
  let daemonMatches = 0;
  for (const [index, raw] of values.entries()) {
    const label = `manifest.files[${String(index)}]`;
    const value = object(raw, label);
    const type = value.type;
    const path = string(value.path, "file path", 4096);
    if (!path.startsWith("/usr/") || path.includes("\0") || paths.has(path))
      return invalidManifest();
    paths.add(path);
    const mode = string(value.mode, "file mode", 4);
    if (!/^[0-7]{4}$/.test(mode)) return invalidManifest();
    const uid = integer(value.uid, "file uid", 0, 0);
    const gid = integer(value.gid, "file gid", 0, 0);
    if (type === "file") {
      exactKeys(
        value,
        ["path", "type", "sha256", "size", "mode", "uid", "gid"],
        label,
      );
      const digest = sha256Hex(value.sha256, "file sha256");
      const size = integer(value.size, "file size", 0, 2_147_483_648);
      rootRecords.push(
        `${path}\0file\0${digest}\0${String(size)}\0${mode}\0${String(uid)}\0${String(gid)}`,
      );
      if (path === daemon.path) {
        daemonMatches += 1;
        if (
          digest !== daemon.sha256 ||
          size === 0 ||
          size > 512 * 1024 * 1024 ||
          mode !== daemon.mode.toString(8).padStart(4, "0") ||
          uid !== daemon.ownerUid ||
          gid !== daemon.ownerGid
        )
          return invalidManifest();
      }
    } else if (type === "symlink") {
      exactKeys(value, ["path", "type", "target", "mode", "uid", "gid"], label);
      const target = string(value.target, "symlink target", 4096);
      if (target.includes("\0")) return invalidManifest();
      rootRecords.push(
        `${path}\0symlink\0${target}\0${mode}\0${String(uid)}\0${String(gid)}`,
      );
    } else {
      return invalidManifest();
    }
  }
  if (daemonMatches !== 1) return invalidManifest();
  rootRecords.sort((left, right) =>
    Buffer.compare(Buffer.from(left), Buffer.from(right)),
  );
  return sha256(rootRecords.join("\n"));
}

function invalidBundle(): never {
  throw new PublicError(400, "bad_request", "Evidence bundle is invalid");
}

function invalidManifest(): never {
  throw new PublicError(
    403,
    "verification_failed",
    "Device attestation was not accepted",
  );
}
