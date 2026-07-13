/** BOLA proof for the uid-free domain-core shadow evidence collection. */
import { describe, it, vi } from "vitest";

import { callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map<string, Record<string, unknown>>());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));

export const BOLA_MANIFEST = {
  submitDomainCoreShadowSamples: ["submitDomainCoreShadowSamples preserves victim tenant data"],
} as const;

describe("BOLA - domain-core shadow evidence", () => {
  it("submitDomainCoreShadowSamples preserves victim tenant data", async () => {
    const mod = await import("../../callables/domainCoreShadowEvidence.js");
    const rawRun = callableRunner(mod.submitDomainCoreShadowSamples);
    const run = (request: unknown) => {
      const authenticated = request as { auth: { token: Record<string, unknown> } };
      authenticated.auth.token.domainCoreShadowChannel = "internal";
      authenticated.auth.token.domainCoreShadowConsumers = ["apple"];
      return rawRun(authenticated);
    };

    await tier2CallableProof(bolaStore, {
      exportedName: "submitDomainCoreShadowSamples",
      run,
      expectedOutcome: "no-side-effect",
      payload: {
        samples: [
          {
            schemaVersion: 1,
            sampleId: "00000000-0000-4000-8000-000000000001",
            domain: "quota",
            consumer: "apple",
            channel: "internal",
            operation: "claude_quota",
            coreVersion: "1.0.0",
            observedAt: new Date().toISOString(),
            outcome: "match",
            mismatchCategory: null,
            legacyMicros: 100,
            rustMicros: 90,
          },
        ],
      },
    });
  });
});
