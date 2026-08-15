import { beforeEach, describe, expect, it, vi } from "vitest";

import { callableRunner } from "./bola/callableBolaHarness.js";
import { DEFAULT_MEMORY_PACKS } from "../usageCuration/catalog.js";

const state = vi.hoisted(() => ({
  visionEligible: vi.fn(),
  assertPurchase: vi.fn(),
  loadCatalog: vi.fn(),
  settlePending: vi.fn(),
  redeemPlay: vi.fn(),
  createSession: vi.fn(),
  getCustomer: vi.fn(),
  enforceAuth: vi.fn(),
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({
    enforceAppCheck: false,
    stripeRedirectURLAllowlist: ["burnbar.ai"],
    stripeMemoryBoostText1mPriceID: "price_text_1m",
    stripeMemoryBoostText5mPriceID: "price_text_5m",
    stripeMemoryBoostVision1mPriceID: "price_vision_1m",
    memoryBoostText1mProductID: "com.openburnbar.memory.boost.text.1m",
    memoryBoostText5mProductID: "com.openburnbar.memory.boost.text.5m",
    memoryBoostVision1mProductID: "com.openburnbar.memory.boost.vision.1m",
    googlePlayMemoryBoostText1mProductID: "com.openburnbar.memory.boost.text.1m",
    googlePlayMemoryBoostText5mProductID: "com.openburnbar.memory.boost.text.5m",
    googlePlayMemoryBoostVision1mProductID: "com.openburnbar.memory.boost.vision.1m",
  }),
}));

vi.mock("../auth.js", () => ({
  enforceAuthAndAppCheck: (...args: unknown[]) => state.enforceAuth(...args),
}));

vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return {
    ...actual,
    wrapCallableHandler: (_name: string, handler: (request: unknown) => Promise<unknown>) => handler,
    logCallableStart: vi.fn(),
    traceIdFromCallableRequest: () => "trace",
  };
});

vi.mock("../callables/shared.js", () => ({
  STRIPE_API_SECRETS: [],
  requireConfiguredStripe: () => ({
    checkout: { sessions: { create: state.createSession } },
  }),
  getOrCreateStripeCustomer: (...args: unknown[]) => state.getCustomer(...args),
  boundedHttpsURL: (value: string) => value,
}));

vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: vi.fn(async (_name: string, fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../usageCuration/eligibility.js", () => ({
  hasActiveMemoryPackVisionEntitlement: (...args: unknown[]) => state.visionEligible(...args),
  assertMemoryPackPurchaseEntitlement: (...args: unknown[]) => state.assertPurchase(...args),
}));

vi.mock("../usageCuration/remoteConfig.js", async () => {
  const actual = await vi.importActual<typeof import("../usageCuration/remoteConfig.js")>(
    "../usageCuration/remoteConfig.js",
  );
  return {
    ...actual,
    loadMemoryPackCatalog: (...args: unknown[]) => state.loadCatalog(...args),
  };
});

vi.mock("../usageCuration/wallet.js", () => ({
  settlePendingMemoryPacks: (...args: unknown[]) => state.settlePending(...args),
}));

vi.mock("../usageCuration/playRail.js", () => ({
  redeemPlayMemoryPack: (...args: unknown[]) => state.redeemPlay(...args),
}));

import {
  createMemoryPackCheckoutSession,
  listMemoryPacks,
  redeemPlayMemoryPack,
  settlePendingMemoryPacks,
} from "../callables/memoryPacks.js";

const UID = "callable-user";
const runList = callableRunner(listMemoryPacks);
const runCheckout = callableRunner(createMemoryPackCheckoutSession);
const runSettle = callableRunner(settlePendingMemoryPacks);
const runPlay = callableRunner(redeemPlayMemoryPack);

function request(data: Record<string, unknown> = {}, uid: string | null = UID): Record<string, unknown> {
  return {
    auth: uid ? { uid, token: {} } : undefined,
    data,
    rawRequest: { headers: {} },
  };
}

describe("Memory Boost callables", () => {
  beforeEach(() => {
    state.visionEligible.mockReset();
    state.assertPurchase.mockReset();
    state.loadCatalog.mockReset();
    state.settlePending.mockReset();
    state.redeemPlay.mockReset();
    state.createSession.mockReset();
    state.getCustomer.mockReset();
    state.enforceAuth.mockReset();
    state.visionEligible.mockResolvedValue(false);
    state.assertPurchase.mockResolvedValue(undefined);
    state.settlePending.mockResolvedValue(1);
    state.getCustomer.mockResolvedValue("cus_1");
    state.createSession.mockResolvedValue({ id: "cs_1", url: "https://checkout.stripe.com/cs_1" });
    state.redeemPlay.mockResolvedValue({
      granted: true,
      pending: false,
      alreadyGranted: false,
      consumed: true,
      packId: "text_1m",
    });
    state.loadCatalog.mockResolvedValue({
      packs: {
        text_1m: DEFAULT_MEMORY_PACKS.text_1m,
        text_5m: DEFAULT_MEMORY_PACKS.text_5m,
        vision_1m: { ...DEFAULT_MEMORY_PACKS.vision_1m, title: "" },
      },
    });
  });

  it("lists offered text packs and hides a Remote-Config-disabled vision pack", async () => {
    const result = await runList(request());
    expect(result).toMatchObject({ visionEligible: false });
    expect(result).toEqual(
      expect.objectContaining({
        packs: expect.arrayContaining([
          expect.objectContaining({ packId: "text_1m" }),
          expect.objectContaining({ packId: "text_5m" }),
        ]),
      }),
    );
    expect(JSON.stringify(result)).not.toContain("vision_1m");
  });

  it("creates a Stripe Checkout session for an offered pack", async () => {
    const result = await runCheckout(
      request({
        packId: "text_1m",
        successUrl: "https://burnbar.ai/account",
        cancelUrl: "https://burnbar.ai/account",
      }),
    );
    expect(state.assertPurchase).toHaveBeenCalledWith(UID, "text_1m");
    expect(state.createSession).toHaveBeenCalledWith(
      expect.objectContaining({
        mode: "payment",
        allow_promotion_codes: false,
        metadata: expect.objectContaining({ kind: "memory_pack", packId: "text_1m" }),
      }),
      expect.objectContaining({ idempotencyKey: expect.stringContaining("memory_pack_checkout") }),
    );
    expect(result).toEqual({ sessionId: "cs_1", url: "https://checkout.stripe.com/cs_1" });
  });

  it("refuses checkout for a hidden pack and unauthenticated callers", async () => {
    await expect(
      runCheckout(
        request({
          packId: "vision_1m",
          successUrl: "https://burnbar.ai/account",
          cancelUrl: "https://burnbar.ai/account",
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    await expect(runList(request({}, null))).rejects.toMatchObject({ code: "unauthenticated" });
    await expect(runSettle(request({}, null))).rejects.toMatchObject({ code: "unauthenticated" });
    await expect(runPlay(request({}, null))).rejects.toMatchObject({ code: "unauthenticated" });
    await expect(
      runCheckout(
        request(
          {
            packId: "text_1m",
            successUrl: "https://burnbar.ai/account",
            cancelUrl: "https://burnbar.ai/account",
          },
          null,
        ),
      ),
    ).rejects.toMatchObject({ code: "unauthenticated" });
  });

  it("settles pending packs and redeems a Play purchase", async () => {
    await expect(runSettle(request())).resolves.toEqual({ settled: 1, visionEligible: false });
    await expect(
      runPlay(
        request({
          purchaseToken: "play-token",
          productID: "com.openburnbar.memory.boost.text.1m",
        }),
      ),
    ).resolves.toMatchObject({ granted: true, packId: "text_1m" });
    expect(state.redeemPlay).toHaveBeenCalledWith({
      uid: UID,
      purchaseToken: "play-token",
      productID: "com.openburnbar.memory.boost.text.1m",
    });
  });
});
