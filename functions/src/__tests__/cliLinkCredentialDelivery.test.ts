import { createDecipheriv, createECDH, createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { Timestamp } from "firebase-admin/firestore";
import { describe, expect, it, vi } from "vitest";

import { callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

const cliLinkStore = vi.hoisted(() => new Map());
const issueGrantMock = vi.hoisted(() => vi.fn());

function cliLinkSessionQuery(filters: Array<[string, unknown]> = []) {
  return {
    where: (field: string, _op: string, value: unknown) => cliLinkSessionQuery([...filters, [field, value]]),
    limit: () => cliLinkSessionQuery(filters),
    orderBy: () => cliLinkSessionQuery(filters),
    get: async () => {
      const base = pathKeyedFirestore(cliLinkStore);
      const docs = Array.from(cliLinkStore.entries())
        .filter(([path, data]) => path.startsWith("cli_link_sessions/") && filters.every(([field, value]) => data[field] === value))
        .map(([path, data]) => ({
          ref: base.doc(path),
          data: () => data,
        }));
      return { docs, empty: docs.length === 0 };
    },
  };
}

function cliLinkFirestore() {
  const base = pathKeyedFirestore(cliLinkStore);
  return {
    ...base,
    collection: (name: string) => {
      const collection = base.collection(name);
      if (name !== "cli_link_sessions") return collection;
      return {
        ...collection,
        where: (field: string, op: string, value: unknown) => cliLinkSessionQuery([[field, value]]),
      };
    },
  };
}

vi.mock("../adminRuntime.js", () => ({ db: cliLinkFirestore() }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(cliLinkStore),
  };
});
vi.mock("../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../appCheckAttestation.js")>("../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
vi.mock("../callables/shared.js", () => ({
  assertActiveBurnBarProEntitlement: vi.fn(async () => undefined),
  REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64: { value: () => "" },
  REMOTE_MCP_TOKEN_HMAC_SECRET: { value: () => "test-hmac-secret" },
}));
vi.mock("../callables/publicRateLimit.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/publicRateLimit.js")>(
    "../callables/publicRateLimit.js",
  );
  return {
    ...actual,
    assertCallableApprovalNotLocked: vi.fn(async () => undefined),
    recordCallableApprovalFailure: vi.fn(async () => undefined),
  };
});
vi.mock("../remoteMcpOAuth.js", () => ({
  issueRemoteMcpGrantForSignedInUser: issueGrantMock,
}));

const DELIVERY_ALGORITHM = "p256-ecdh-aes-256-gcm-v1";
const DELIVERY_KEY_CONTEXT = "OpenBurnBar CLI link credential delivery v1";

class FakeRes extends EventEmitter {
  statusCode = 0;
  body: unknown;
  private headers: Record<string, string> = {};

  status(code: number): this {
    this.statusCode = code;
    return this;
  }

  json(payload: unknown): void {
    this.body = payload;
    this.emit("finish");
  }

  setHeader(name: string, value: string): void {
    this.headers[name.toLowerCase()] = value;
  }

  getHeader(name: string): string | undefined {
    return this.headers[name.toLowerCase()];
  }
}

async function runHttpHandler(handler: unknown, req: unknown, res: unknown): Promise<void> {
  const run = Reflect.get(Object(handler), "run");
  const callable = typeof run === "function" ? run.bind(handler) : handler;
  if (typeof callable !== "function") throw new Error("Expected HTTP handler to be callable");
  await callable(req, res);
}

function sha256Hex(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function deliveryKey(secret: Buffer): Buffer {
  return createHash("sha256").update(DELIVERY_KEY_CONTEXT).update("\0").update(secret).digest();
}

describe("CLI link credential delivery", () => {
  it("seals credentials to the polling client's delivery key", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    const { sealCliLinkCredentialsForDelivery } = await import("../callables/cliLink.js");

    const envelope = sealCliLinkCredentialsForDelivery(
      {
        algorithm: DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
      },
      {
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresIn: 900,
        clientId: "client-1",
        scopes: ["search:read"],
        grantMode: "local_decrypt_shim",
      },
    );

    expect(JSON.stringify(envelope)).not.toContain("access-secret");
    expect(JSON.stringify(envelope)).not.toContain("refresh-secret");

    const sharedSecret = delivery.computeSecret(Buffer.from(envelope.ephemeralPublicKeyBase64, "base64"));
    const decipher = createDecipheriv(
      "aes-256-gcm",
      deliveryKey(sharedSecret),
      Buffer.from(envelope.ivBase64, "base64"),
    );
    decipher.setAAD(Buffer.from(envelope.aad, "utf8"));
    decipher.setAuthTag(Buffer.from(envelope.authTagBase64, "base64"));
    const plaintext = Buffer.concat([
      decipher.update(Buffer.from(envelope.ciphertextBase64, "base64")),
      decipher.final(),
    ]);

    expect(JSON.parse(plaintext.toString("utf8"))).toMatchObject({
      accessToken: "access-secret",
      refreshToken: "refresh-secret",
      clientId: "client-1",
    });
  });

  it("starts sessions with a verifier hash and delivery key, not the raw device-secret hash", async () => {
    cliLinkStore.clear();
    const deviceSecret = "device-secret-for-link";
    const deviceSecretHash = sha256Hex(deviceSecret);
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();

    const req = {
      method: "POST",
      body: {
        clientType: "cli",
        displayName: "local-cli",
        deviceSecretHash,
        credentialDelivery: {
          algorithm: DELIVERY_ALGORITHM,
          publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        },
      },
      headers: {},
      socket: { remoteAddress: "127.0.0.1" },
    };
    const res = new FakeRes();

    const { startCliLink } = await import("../callables/cliLink.js");
    await runHttpHandler(startCliLink, req, res);

    expect(res.statusCode).toBe(200);
    const response = res.body as { deviceCode: string };
    const stored = cliLinkStore.get(`cli_link_sessions/${response.deviceCode}`);
    expect(stored).toBeTruthy();
    expect(stored.deviceSecretHash).toBeUndefined();
    expect(stored.deviceSecretVerifierHash).toBe(sha256Hex(deviceSecretHash));
    expect(stored.credentialDelivery).toMatchObject({
      algorithm: DELIVERY_ALGORITHM,
      publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
    });
  });

  it("rejects malformed delivery sessions before issuing a remote grant", async () => {
    cliLinkStore.clear();
    issueGrantMock.mockReset();
    const deviceSecretHash = sha256Hex("legacy-device-secret");

    seedDoc(cliLinkStore, "cli_link_sessions/legacy-session", {
      userCode: "ABCDEFGHJKMN",
      deviceSecretVerifierHash: sha256Hex(deviceSecretHash),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      clientType: "cli",
      displayName: "legacy-cli",
      credentialDelivery: {
        algorithm: DELIVERY_ALGORITHM,
        publicKeyBase64: "not-a-valid-p256-key",
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    const run = callableRunner(completeCliLink);

    await expect(
      run(callableRequest("alice-uid", { userCode: "ABCDEFGHJKMN", nonce: "nonce-1" })),
    ).rejects.toMatchObject({ code: "invalid-argument" });
    expect(issueGrantMock).not.toHaveBeenCalled();
  });
});
