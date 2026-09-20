/**
 * BOLA negative coverage — pairing callables + CLI link HTTP poll.
 */

import { describe, it, vi, expect } from "vitest";
import { callableRunner, pathKeyedFirestore, seedDoc, tier2CallableProof } from "./callableBolaHarness.js";

import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { Timestamp } from "firebase-admin/firestore";


process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(bolaStore),
  };
});

vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../../appCheckAttestation.js")>("../../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});

export const BOLA_MANIFEST = {
  pollCliLink: ["pollCliLink rejects cross-user object access"],
  completeCliLink: ["completeCliLink rejects cross-user object access"],
  createHermesPairing: ["createHermesPairing rejects cross-user object access"],
  completeHermesPairing: ["completeHermesPairing rejects cross-user object access"],
  createPiAgentPairing: ["createPiAgentPairing rejects cross-user object access"],
  completePiAgentPairing: ["completePiAgentPairing rejects cross-user object access"],
} as const;

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
  end(): void {
    this.emit("finish");
  }
}

async function runHttpHandler(handler: unknown, req: unknown, res: unknown): Promise<void> {
  const run = Reflect.get(Object(handler), "run");
  const callable = typeof run === "function" ? run.bind(handler) : handler;
  if (typeof callable !== "function") {
    throw new Error("Expected HTTP handler to be callable");
  }
  await callable(req, res);
}

describe("BOLA — pairing", () => {
  it("pollCliLink rejects cross-user object access", async () => {
    const bobSecret = "bob-device-secret";
    const bobSecretHash = createHash("sha256").update(bobSecret).digest("hex");
    bolaStore.clear();
    seedDoc(bolaStore, "cli_link_sessions/bob-device-code", {
      userCode: "ABCDEFGHJKMN",
      deviceSecretHash: bobSecretHash,
      status: "approved",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      accessToken: "bob-access",
      refreshToken: "bob-refresh",
      expiresIn: 3600,
      clientId: "bob-client",
      scopes: ["cli"],
      grantMode: "device",
    });

    const res = new FakeRes();
    const req = {
      method: "POST",
      body: { deviceCode: "bob-device-code", deviceSecret: "wrong-secret" },
      headers: {},
      socket: { remoteAddress: "127.0.0.1" },
    };

    const { pollCliLink } = await import("../../callables/cliLink.js");
    await runHttpHandler(pollCliLink, req, res);

    // Catalog expectedCode: permission-denied — HTTP 403 when deviceSecret does not match session.
    expect(res.statusCode).toBe(403);
    expect(res.body).toMatchObject({ error: "invalid_secret" });
  });

  it("completeCliLink rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliLink.js");
    const run = callableRunner(mod.completeCliLink);

    await tier2CallableProof(bolaStore, {
      exportedName: "completeCliLink",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("createHermesPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermes.js");
    const run = callableRunner(mod.createHermesPairing);

    await tier2CallableProof(bolaStore, {
      exportedName: "createHermesPairing",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("completeHermesPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermes.js");
    const run = callableRunner(mod.completeHermesPairing);

    await tier2CallableProof(bolaStore, {
      exportedName: "completeHermesPairing",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("createPiAgentPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/piAgent.js");
    const run = callableRunner(mod.createPiAgentPairing);

    await tier2CallableProof(bolaStore, {
      exportedName: "createPiAgentPairing",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("completePiAgentPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/piAgent.js");
    const run = callableRunner(mod.completePiAgentPairing);

    await tier2CallableProof(bolaStore, {
      exportedName: "completePiAgentPairing",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });
});
