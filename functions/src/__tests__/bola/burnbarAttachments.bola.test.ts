/**
 * BOLA negative coverage — burnbar_attachments object ownership.
 */

import { describe, it, vi } from "vitest";
import { callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../../callables/shared.js")>("../../callables/shared.js");
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});
vi.mock("../../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
}));
vi.mock("../../callables/computerUseSecurityFirestore.js", () => ({
  requireTrustedDeviceActionProof: vi.fn(async () => ({ deviceId: "dev", platform: "iOS", signalIdentityKeyId: "s" })),
}));

export const BOLA_MANIFEST = {
  beginBurnbarAttachment: ["beginBurnbarAttachment rejects cross-user object access"],
  mintBurnbarAttachmentPartURL: ["mintBurnbarAttachmentPartURL rejects cross-user object access"],
  composeBurnbarAttachment: ["composeBurnbarAttachment rejects cross-user object access"],
  finalizeBurnbarAttachment: ["finalizeBurnbarAttachment rejects cross-user object access"],
  deleteBurnbarAttachment: ["deleteBurnbarAttachment rejects cross-user object access"],
  ticketBurnbarAttachmentDownload: ["ticketBurnbarAttachmentDownload rejects cross-user object access"],
} as const;

describe("BOLA — burnbarAttachments", () => {
  it("beginBurnbarAttachment rejects cross-user object access", async () => {
    const mod = await import("../../callables/burnbarAttachments.js");
    const run = callableRunner(mod.beginBurnbarAttachment);
    await tier2CallableProof(bolaStore, {
      exportedName: "beginBurnbarAttachment",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("mintBurnbarAttachmentPartURL rejects cross-user object access", async () => {
    const mod = await import("../../callables/burnbarAttachments.js");
    const run = callableRunner(mod.mintBurnbarAttachmentPartURL);
    await tier2CallableProof(bolaStore, {
      exportedName: "mintBurnbarAttachmentPartURL",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("composeBurnbarAttachment rejects cross-user object access", async () => {
    const mod = await import("../../callables/burnbarAttachments.js");
    const run = callableRunner(mod.composeBurnbarAttachment);
    await tier2CallableProof(bolaStore, {
      exportedName: "composeBurnbarAttachment",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("finalizeBurnbarAttachment rejects cross-user object access", async () => {
    const mod = await import("../../callables/burnbarAttachments.js");
    const run = callableRunner(mod.finalizeBurnbarAttachment);
    await tier2CallableProof(bolaStore, {
      exportedName: "finalizeBurnbarAttachment",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("deleteBurnbarAttachment rejects cross-user object access", async () => {
    const mod = await import("../../callables/burnbarAttachments.js");
    const run = callableRunner(mod.deleteBurnbarAttachment);
    await tier2CallableProof(bolaStore, {
      exportedName: "deleteBurnbarAttachment",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("ticketBurnbarAttachmentDownload rejects cross-user object access", async () => {
    const mod = await import("../../callables/burnbarAttachments.js");
    const run = callableRunner(mod.ticketBurnbarAttachmentDownload);
    await tier2CallableProof(bolaStore, {
      exportedName: "ticketBurnbarAttachmentDownload",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });
});
