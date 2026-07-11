import assert from "node:assert/strict";
import { sign } from "node:crypto";
import { describe, it } from "node:test";
import { parseEvidenceBundle, verifyInstalledManifest } from "../src/evidenceBundle.js";
import { PublicError } from "../src/errors.js";
import { fixture, policy, releaseKeys } from "./helpers.js";

function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) as string;
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const source = value as Record<string, unknown>;
  return `{${Object.keys(source).sort().map(key => `${JSON.stringify(key)}:${canonical(source[key])}`).join(",")}}`;
}

function header(bundle: Buffer): { length: number; value: { schemaVersion: number; records: Array<{ kind: string; offset: number; byteLength: number; sha256: string }> } } {
  const length = bundle.readUInt32BE(8);
  return { length, value: JSON.parse(bundle.subarray(12, 12 + length).toString()) as { schemaVersion: number; records: Array<{ kind: string; offset: number; byteLength: number; sha256: string }> } };
}

function rewriteCanonical(bundle: Buffer, mutate: (value: ReturnType<typeof header>["value"]) => void): Buffer {
  const parsed = header(bundle);
  mutate(parsed.value);
  const bytes = Buffer.from(canonical(parsed.value));
  assert.equal(bytes.byteLength, parsed.length);
  return Buffer.concat([bundle.subarray(0, 8), Buffer.from([(bytes.length >>> 24) & 255, (bytes.length >>> 16) & 255, (bytes.length >>> 8) & 255, bytes.length & 255]), bytes, bundle.subarray(12 + parsed.length)]);
}

describe("OBBATST1 parser", () => {
  it("accepts the canonical four-record bundle", () => {
    const parsed = parseEvidenceBundle(fixture().bytes);
    assert.equal(parsed.imaLog.toString(), "ima");
    assert.equal(parsed.uefiLog.toString(), "uefi");
  });

  for (const [name, mutation] of [
    ["bad magic", (bytes: Buffer) => { bytes[0] = 0; return bytes; }],
    ["record hash mismatch", (bytes: Buffer) => { bytes[bytes.length - 1] = (bytes[bytes.length - 1] ?? 0) ^ 1; return bytes; }],
    ["trailing data", (bytes: Buffer) => Buffer.concat([bytes, Buffer.from([0])])],
    ["oversize descriptor", () => Buffer.alloc(16 * 1024 * 1024 + 1)],
  ] as const) {
    it(`rejects ${name}`, () => {
      const value = mutation(Buffer.from(fixture().bytes));
      assert.throws(() => parseEvidenceBundle(value), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    });
  }

  it("rejects wrong record order", () => {
    const bytes = rewriteCanonical(fixture().bytes, value => {
      const first = value.records[0]!.kind;
      value.records[0]!.kind = value.records[1]!.kind;
      value.records[1]!.kind = first;
    });
    assert.throws(() => parseEvidenceBundle(bytes), PublicError);
  });

  it("requires the broker's exact ASCII IMA record kind", () => {
    const bytes = rewriteCanonical(fixture().bytes, value => {
      value.records[0]!.kind = "ima_xscii_runtime_measurements";
    });
    assert.throws(() => parseEvidenceBundle(bytes), PublicError);
  });

  it("rejects record gaps and overlaps", () => {
    for (const delta of [-1, 1]) {
      const bytes = rewriteCanonical(fixture().bytes, value => { value.records[1]!.offset += delta; });
      assert.throws(() => parseEvidenceBundle(bytes), PublicError);
    }
  });

  it("rejects a noncanonical JSON header even when it is valid JSON", () => {
    const original = fixture().bytes;
    const parsed = header(original);
    const noncanonical = Buffer.from(JSON.stringify({ schemaVersion: parsed.value.schemaVersion, records: parsed.value.records }));
    assert.equal(noncanonical.byteLength, parsed.length);
    const bytes = Buffer.concat([original.subarray(0, 12), noncanonical, original.subarray(12 + parsed.length)]);
    assert.throws(() => parseEvidenceBundle(bytes), PublicError);
  });

  it("rejects deeply nested untrusted headers without recursive canonicalization", () => {
    const nested = `${"[".repeat(3_000)}0${"]".repeat(3_000)}`;
    const headerBytes = Buffer.from(`{"records":[${nested},{},{},{}],"schemaVersion":1}`);
    const prefix = Buffer.alloc(12);
    prefix.write("OBBATST1", 0, "ascii");
    prefix.writeUInt32BE(headerBytes.byteLength, 8);
    const bytes = Buffer.concat([prefix, headerBytes, Buffer.from([0])]);
    assert.throws(
      () => parseEvidenceBundle(bytes),
      (error: unknown) => error instanceof PublicError && error.code === "bad_request",
    );
  });
});

describe("installed manifest verification", () => {
  it("accepts a valid signed manifest bound to the challenge", () => {
    const data = fixture();
    const parsed = parseEvidenceBundle(data.bytes);
    assert.equal(parsed.installedManifest.at(-1), 0x0a);
    verifyInstalledManifest(parsed, data.challenge, policy.releaseManifestPublicKeyPem);
  });

  it("rejects detached signature and binding mismatches", async () => {
    const data = fixture();
    const parsed = parseEvidenceBundle(data.bytes);
    const signature = Buffer.from(parsed.installedManifestSignature);
    signature[0] = (signature[0] ?? 0) ^ 1;
    assert.throws(() => verifyInstalledManifest({ ...parsed, installedManifestSignature: signature }, data.challenge, policy.releaseManifestPublicKeyPem), PublicError);
    const wrongBinding = structuredClone(data.challenge);
    wrongBinding.appVersion = "9.9.9";
    assert.throws(() => verifyInstalledManifest(parsed, wrongBinding, policy.releaseManifestPublicKeyPem), PublicError);
    const withoutNewline = parsed.installedManifest.subarray(0, -1);
    const noNewlineSignature = sign(null, withoutNewline, releaseKeys.privateKey);
    const noNewlineChallenge = structuredClone(data.challenge);
    noNewlineChallenge.releaseDigestSha256 = (await import("../src/validation.js")).sha256(withoutNewline);
    assert.throws(() => verifyInstalledManifest({ ...parsed, installedManifest: withoutNewline, installedManifestSignature: noNewlineSignature }, noNewlineChallenge, policy.releaseManifestPublicKeyPem), PublicError);
  });

  it("rejects malformed authorized clients, file entries, and inventory roots after valid signing", async () => {
    const cases: Array<(manifest: Record<string, unknown>) => void> = [
      manifest => { ((manifest.authorizedClients as Array<Record<string, unknown>>)[0]!).mode = 0o777; },
      manifest => { ((manifest.files as Array<Record<string, unknown>>)[0]!).extra = true; },
      manifest => { manifest.installedFilesRootSha256 = "f".repeat(64); },
    ];
    for (const mutate of cases) {
      const data = fixture();
      const parsed = parseEvidenceBundle(data.bytes);
      const manifest = JSON.parse(parsed.installedManifest.toString()) as Record<string, unknown>;
      mutate(manifest);
      const manifestBytes = Buffer.from(`${canonical(manifest)}\n`);
      const signature = sign(null, manifestBytes, releaseKeys.privateKey);
      data.challenge.releaseDigestSha256 = (await import("../src/validation.js")).sha256(manifestBytes);
      assert.throws(() => verifyInstalledManifest({ ...parsed, installedManifest: manifestBytes, installedManifestSignature: signature }, data.challenge, policy.releaseManifestPublicKeyPem), PublicError);
    }
  });
});
