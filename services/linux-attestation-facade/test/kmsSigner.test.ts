import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { crc32c, KmsEd25519Signer } from "../src/kmsSigner.js";
import type { KeyManagementServiceClient } from "@google-cloud/kms";

const keyName = "projects/p/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1";

function client(overrides: {
  state?: number;
  algorithm?: number;
  verified?: boolean;
  signature?: Buffer;
  metadataFailure?: { remaining: number; calls: number };
} = {}): KeyManagementServiceClient {
  const signature = overrides.signature ?? Buffer.alloc(64, 7);
  return {
    async getCryptoKeyVersion() {
      if (overrides.metadataFailure !== undefined) {
        overrides.metadataFailure.calls += 1;
        if (overrides.metadataFailure.remaining > 0) {
          overrides.metadataFailure.remaining -= 1;
          throw new Error("transient metadata outage");
        }
      }
      return [{ name: keyName, state: overrides.state ?? 1, algorithm: overrides.algorithm ?? 40 }];
    },
    async asymmetricSign(request: { data?: Uint8Array | string | null; dataCrc32c?: { value?: number | string | null } }) {
      const data = Buffer.from(request.data as Uint8Array);
      assert.equal(Number(request.dataCrc32c?.value), crc32c(data));
      return [{ name: keyName, verifiedDataCrc32c: overrides.verified ?? true, signature, signatureCrc32c: { value: crc32c(signature) } }];
    },
  } as unknown as KeyManagementServiceClient;
}

describe("KmsEd25519Signer", () => {
  it("requires enabled Ed25519 and validates request/response CRC32C", async () => {
    assert.equal(crc32c(Buffer.from("123456789")), 0xe3069283);
    const signer = new KmsEd25519Signer(keyName, client());
    assert.equal((await signer.sign(Buffer.from("verdict"))).byteLength, 64);
  });
  it("rejects wrong algorithm, disabled key, CRC rejection, and non-Ed25519 signature length", async () => {
    await assert.rejects(new KmsEd25519Signer(keyName, client({ algorithm: 12 })).sign(Buffer.from("x")));
    await assert.rejects(new KmsEd25519Signer(keyName, client({ state: 2 })).sign(Buffer.from("x")));
    await assert.rejects(new KmsEd25519Signer(keyName, client({ verified: false })).sign(Buffer.from("x")));
    await assert.rejects(new KmsEd25519Signer(keyName, client({ signature: Buffer.alloc(63) })).sign(Buffer.from("x")));
  });
  it("coalesces key readiness and retries after a transient metadata failure", async () => {
    const metadataFailure = { remaining: 1, calls: 0 };
    const signer = new KmsEd25519Signer(keyName, client({ metadataFailure }));
    await assert.rejects(signer.sign(Buffer.from("first")), /transient metadata outage/);
    assert.equal((await signer.sign(Buffer.from("second"))).byteLength, 64);
    assert.equal(metadataFailure.calls, 2);
  });
});
