/**
 * Lazy googleapis loading in the billing callables (perf finding crosscut-002).
 *
 * stripe.ts used to value-import googleapis at module scope; since all
 * deployed functions share one bundle, that ~500ms require tax landed on every
 * cold start — including the many functions that never touch Play billing.
 * The import is now deferred to first use inside the two Google Play
 * verification handlers. These tests drive the REAL handlers through
 * `.run(request)` with a load-counting googleapis mock to prove:
 *  - importing the stripe module does NOT load googleapis;
 *  - each Google Play handler loads it on demand and still completes its full
 *    verify → claim → entitle/credit → billing-record pipeline;
 *  - repeat invocations reuse the cached module (the loader runs once);
 *  - the source keeps exactly the two deferred import sites and no top-level
 *    value import (the regression the perf fix exists to prevent).
 */

import { describe, expect, it, beforeEach, vi } from "vitest";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const state = vi.hoisted(() => {
  const docSets: Array<{ path: string; data: Record<string, unknown> }> = [];
  return {
    googleapisLoads: 0,
    getClient: vi.fn(),
    subscriptionsV2Get: vi.fn(),
    productsGet: vi.fn(),
    productsConsume: vi.fn(),
    claimMock: vi.fn(),
    writeEntitlementMock: vi.fn(),
    creditMock: vi.fn(),
    assertActiveMock: vi.fn(),
    enforceMock: vi.fn(),
    docSets,
  };
});

vi.mock("googleapis", () => {
  state.googleapisLoads += 1;
  return {
    google: {
      auth: { getClient: state.getClient },
      androidpublisher: vi.fn(() => ({
        purchases: {
          subscriptionsv2: { get: state.subscriptionsV2Get },
          products: { get: state.productsGet, consume: state.productsConsume },
        },
      })),
    },
  };
});

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc: (path: string) => ({
      set: async (data: Record<string, unknown>) => {
        state.docSets.push({ path, data });
      },
    }),
  },
}));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: state.enforceMock }));
vi.mock("../config.js", () => ({
  getConfig: () => ({
    enforceAppCheck: false,
    googlePlayPackageName: "ai.openburnbar.app",
    googlePlaySubscriptionProductID: "burnbar_cloud_monthly",
    googlePlayCloudMonthlyProductID: "burnbar_cloud_monthly",
    googlePlayCloudAnnualProductID: "burnbar_cloud_annual",
    burnBarProProductID: "burnbar_pro_legacy",
    burnBarProAnnualProductID: "burnbar_pro_legacy_annual",
    googlePlayCloudProMonthlyProductID: "burnbar_cloud_pro_monthly",
    googlePlayCloudProAnnualProductID: "burnbar_cloud_pro_annual",
    burnBarProMaxProductID: "burnbar_pro_max_legacy",
    burnBarProMaxAnnualProductID: "burnbar_pro_max_legacy_annual",
    googlePlayUltraMonthlyProductID: "burnbar_ultra_monthly",
    googlePlayUltraAnnualProductID: "burnbar_ultra_annual",
    burnBarUltraProductID: "burnbar_ultra_legacy",
    burnBarUltraAnnualProductID: "burnbar_ultra_legacy_annual",
    googlePlayAgentControl100ActionsProductID: "gp_agent_control_100",
    agentControl100ActionsProductID: "agent_control_100",
    googlePlayFlooRelay50GBProductID: "gp_floo_relay_50gb",
    flooRelay50GBProductID: "floo_relay_50gb",
  }),
}));
vi.mock("../resilienceHelpers.js", () => ({
  externalApiWithResilience: vi.fn(async <T>(_name: string, fn: () => Promise<T>) => fn()),
  stripeWithResilience: vi.fn(async <T>(_name: string, fn: () => Promise<T>) => fn()),
}));
vi.mock("../callables/googlePlayTokenClaims.js", () => ({ claimGooglePlayPurchaseToken: state.claimMock }));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logError: vi.fn(), logWarn: vi.fn() };
});
// Typed fake of the shared billing helpers: the Firestore/Stripe-touching
// functions are stubs wired to the hoisted state; the pure helpers mirror the
// real contracts closely enough for the handlers' happy paths.
vi.mock("../callables/shared.js", async () => {
  const { createHash: hash } = await import("node:crypto");
  return {
    BURNBAR_PRO_ENTITLEMENT_ID: "burnbar_pro",
    BURNBAR_PRO_MAX_ENTITLEMENT_ID: "burnbar_pro_max",
    BURNBAR_ULTRA_ENTITLEMENT_ID: "burnbar_ultra",
    STRIPE_API_SECRETS: [],
    STRIPE_WEBHOOK_SECRETS: [],
    GOOGLE_PLAY_ACTIVE_STATES: new Set(["SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"]),
    nowISO: () => new Date().toISOString(),
    boundedTrimmedString: (raw: unknown, fieldName: string, _maxLength: number, required?: boolean) => {
      if (typeof raw === "string" && raw.trim().length > 0) return raw.trim();
      if (required) throw new Error(`${fieldName} is required.`);
      return undefined;
    },
    sha256Hex: (text: string) => hash("sha256").update(text).digest("hex"),
    requireConfiguredStripe: vi.fn(),
    requireConfiguredStripeWebhookSecret: vi.fn(),
    boundedHttpsURL: vi.fn(),
    assertActiveBurnBarCloudProEntitlement: state.assertActiveMock,
    getOrCreateStripeCustomer: vi.fn(),
    googlePlayLineItemForProduct: (purchase: { lineItems?: Array<{ productId?: unknown }> }, productID: string) =>
      purchase.lineItems?.find((item) => item.productId === productID),
    googlePlayExpiryMillis: (lineItem?: { expiryTime?: unknown }) =>
      lineItem && typeof lineItem.expiryTime === "string" ? Date.parse(lineItem.expiryTime) : 0,
    applyStripeCheckoutSession: vi.fn(),
    applyStripeSubscription: vi.fn(),
    creditCloudProTopUp: state.creditMock,
    writeBurnBarProEntitlement: state.writeEntitlementMock,
  };
});

import { verifyGooglePlayBurnBarProSubscription, verifyGooglePlayCloudProTopUp } from "../callables/stripe.js";

const UID = "user-billing-1";
const SUBSCRIPTION_TOKEN = "gp-subscription-token-1";
const TOPUP_TOKEN = "gp-topup-token-1";
const EXPIRY_ISO = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

function tokenHash(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function req(data: Record<string, unknown>) {
  return {
    auth: { uid: UID },
    data,
    rawRequest: { headers: {} },
  };
}

/**
 * Single typed seam for driving the real callables through `.run(request)`.
 * Funnelling every invocation through this helper keeps the unavoidable
 * mock-request widening to exactly one cast instead of one per call site.
 */
function invokeCallable<TRes = unknown>(callable: unknown, data: Record<string, unknown>): Promise<TRes> {
  const runnable = callable as { run: (request: unknown) => Promise<TRes> };
  return runnable.run(req(data));
}

beforeEach(() => {
  vi.clearAllMocks();
  state.docSets.length = 0;
  state.getClient.mockResolvedValue({});
  state.claimMock.mockResolvedValue(undefined);
  state.assertActiveMock.mockResolvedValue(undefined);
  state.subscriptionsV2Get.mockResolvedValue({
    data: {
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      lineItems: [{ productId: "burnbar_cloud_monthly", expiryTime: EXPIRY_ISO }],
    },
  });
  state.productsGet.mockResolvedValue({ data: { purchaseState: 0, consumptionState: 0, orderId: "GPA.0001" } });
  state.productsConsume.mockResolvedValue({ data: {} });
  state.writeEntitlementMock.mockResolvedValue({ entitlementID: "burnbar_pro", active: true });
  state.creditMock.mockResolvedValue({ credited: true, monthKey: "2026-06", units: 100, kind: "agent_control_actions_100" });
});

describe("lazy googleapis loading", () => {
  it("importing the stripe module does not load googleapis", () => {
    // The top-of-file import of ../callables/stripe.js already ran; the
    // counting mock proves the cold-start path never touched googleapis.
    expect(state.googleapisLoads).toBe(0);
  });

  it("keeps exactly the two deferred import sites and no top-level value import", () => {
    const source = readFileSync(resolve(__dirname, "../callables/stripe.ts"), "utf8");
    const eagerImport = /^import\s+(?!type\b)[^;]*?from\s+["']googleapis["']|^import\s*["']googleapis["']/mu;

    expect(eagerImport.test(source)).toBe(false);
    expect(source.match(/await import\("googleapis"\)/gu)).toHaveLength(2);
  });
});

describe("verifyGooglePlayBurnBarProSubscription", () => {
  it("loads googleapis on demand and completes verify -> claim -> entitle -> billing record", async () => {
    const res = await invokeCallable<{ active: boolean; subscriptionState: string; expiresAt: string }>(
      verifyGooglePlayBurnBarProSubscription,
      { purchaseToken: SUBSCRIPTION_TOKEN },
    );

    expect(state.googleapisLoads).toBe(1);
    expect(state.getClient).toHaveBeenCalledWith({ scopes: ["https://www.googleapis.com/auth/androidpublisher"] });
    expect(state.subscriptionsV2Get).toHaveBeenCalledWith({
      packageName: "ai.openburnbar.app",
      token: SUBSCRIPTION_TOKEN,
    });
    expect(state.claimMock).toHaveBeenCalledWith({
      uid: UID,
      purchaseTokenHash: tokenHash(SUBSCRIPTION_TOKEN),
      productID: "burnbar_cloud_monthly",
      kind: "subscription",
    });
    expect(state.writeEntitlementMock).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: UID,
        productID: "burnbar_cloud_monthly",
        entitlementID: "burnbar_pro",
        source: "google_play_verified",
        platform: "android",
        activeOverride: true,
        expiresAtMillis: Date.parse(EXPIRY_ISO),
      }),
    );
    expect(state.docSets.map((entry) => entry.path)).toContain(
      `users/${UID}/billing/google_play_purchases/tokens/${tokenHash(SUBSCRIPTION_TOKEN)}`,
    );
    expect(res.active).toBe(true);
    expect(res.subscriptionState).toBe("SUBSCRIPTION_STATE_ACTIVE");
    expect(res.expiresAt).toBe(EXPIRY_ISO);
  });

  it("reports an expired-but-known subscription as inactive", async () => {
    state.subscriptionsV2Get.mockResolvedValue({
      data: {
        subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
        lineItems: [{ productId: "burnbar_cloud_monthly", expiryTime: "2020-01-01T00:00:00.000Z" }],
      },
    });

    const res = await invokeCallable<{ active: boolean }>(verifyGooglePlayBurnBarProSubscription, {
      purchaseToken: SUBSCRIPTION_TOKEN,
    });

    expect(res.active).toBe(false);
    expect(state.writeEntitlementMock).toHaveBeenCalledWith(expect.objectContaining({ activeOverride: false }));
  });
});

describe("verifyGooglePlayCloudProTopUp", () => {
  it("loads googleapis at most once across handlers (cached module, loader runs a single time)", async () => {
    const res = await invokeCallable<{ credited: boolean; purchaseState: number; consumed: boolean }>(
      verifyGooglePlayCloudProTopUp,
      { purchaseToken: TOPUP_TOKEN, productID: "gp_agent_control_100" },
    );

    expect(state.googleapisLoads).toBe(1);
    expect(state.assertActiveMock).toHaveBeenCalledWith(UID);
    expect(state.productsGet).toHaveBeenCalledWith({
      packageName: "ai.openburnbar.app",
      productId: "gp_agent_control_100",
      token: TOPUP_TOKEN,
    });
    expect(state.claimMock).toHaveBeenCalledWith({
      uid: UID,
      purchaseTokenHash: tokenHash(TOPUP_TOKEN),
      productID: "gp_agent_control_100",
      kind: "topup",
    });
    expect(state.creditMock).toHaveBeenCalledWith({
      uid: UID,
      kind: "agent_control_actions_100",
      source: "google_play",
      externalPaymentID: tokenHash(TOPUP_TOKEN),
    });
    // consumptionState 0 -> the handler consumes the purchase.
    expect(state.productsConsume).toHaveBeenCalledWith({
      packageName: "ai.openburnbar.app",
      productId: "gp_agent_control_100",
      token: TOPUP_TOKEN,
    });
    expect(state.docSets.map((entry) => entry.path)).toContain(
      `users/${UID}/billing/google_play_topups/tokens/${tokenHash(TOPUP_TOKEN)}`,
    );
    expect(res).toEqual({
      credited: true,
      monthKey: "2026-06",
      units: 100,
      kind: "agent_control_actions_100",
      purchaseState: 0,
      consumed: true,
    });
  });

  it("rejects a top-up that is not in the purchased state without crediting", async () => {
    state.productsGet.mockResolvedValue({ data: { purchaseState: 1, consumptionState: 0 } });

    await expect(
      invokeCallable(verifyGooglePlayCloudProTopUp, { purchaseToken: TOPUP_TOKEN, productID: "gp_agent_control_100" }),
    ).rejects.toThrow(/not in the purchased state/);
    expect(state.creditMock).not.toHaveBeenCalled();
    expect(state.productsConsume).not.toHaveBeenCalled();
  });
});
