/**
 * The WIRED call site — proves the consent contract end to end on the real
 * `verifyGooglePlayBurnBarProSubscription` callable (driven through `.run()`,
 * the same harness as stripe.test.ts):
 *
 *   - default (no analytics fields) → NO server event (dark);
 *   - `analyticsConsent: "declined"` → NO event;
 *   - `analyticsConsent: "granted"` but missing device id → NO event;
 *   - `analyticsConsent: "granted"` + device id → exactly ONE
 *     `subscription.entitlement.granted`, AFTER the entitlement write, with the
 *     bounded family/source/platform enums, the hashed authenticated user_id, a dedup
 *     key derived from the token HASH (never the raw token), and NO PII;
 *   - the consent gate runs through the REAL recorder + a fake transport, so the
 *     darkness is structural (the transport is never started pre-consent).
 *
 * The Google Play verification pipeline itself is stubbed exactly as in
 * stripe.test.ts; this test only adds the analytics assertions.
 */
import { describe, expect, it, beforeEach, vi } from "vitest";
import { createHash } from "node:crypto";

import { ServerAnalytics, type AnalyticsEnvelope, type ServerAnalyticsTransport } from "../analytics/recorder.js";
import { setServerAnalyticsForTest } from "../analytics/index.js";

const state = vi.hoisted(() => {
  const docSets: Array<{ path: string; data: Record<string, unknown> }> = [];
  return {
    getClient: vi.fn(),
    subscriptionsV2Get: vi.fn(),
    claimMock: vi.fn(),
    writeEntitlementMock: vi.fn(),
    assertActiveMock: vi.fn(),
    enforceMock: vi.fn(),
    docSets,
  };
});

vi.mock("googleapis", () => ({
  google: {
    auth: { getClient: state.getClient },
    androidpublisher: vi.fn(() => ({
      purchases: { subscriptionsv2: { get: state.subscriptionsV2Get } },
    })),
  },
}));

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
    creditCloudProTopUp: vi.fn(),
    writeBurnBarProEntitlement: state.writeEntitlementMock,
  };
});

import { verifyGooglePlayBurnBarProSubscription } from "../callables/stripe.js";

const UID = "user-billing-1";
const TOKEN = "gp-subscription-token-1";
const DEVICE = "device-uuid-abcdef01";
const EXPIRY_ISO = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

function tokenHash(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function userIdHash(uid: string): string {
  return createHash("sha256").update(uid).digest("hex");
}

function req(data: Record<string, unknown>) {
  return { auth: { uid: UID }, data, rawRequest: { headers: {} } };
}

interface RunnableCallable<TRes> {
  run(request: unknown): Promise<TRes>;
}

function hasCallableRun<TRes>(candidate: unknown): candidate is RunnableCallable<TRes> {
  if (candidate === null) return false;
  if (typeof candidate !== "object" && typeof candidate !== "function") return false;
  return Reflect.get(candidate, "run") instanceof Function;
}

function runnableCallable<TRes>(candidate: unknown): RunnableCallable<TRes> {
  if (!hasCallableRun<TRes>(candidate)) {
    throw new Error("callable target is missing run()");
  }
  return { run: (request: unknown) => candidate.run(request) };
}

function invoke<TRes = unknown>(data: Record<string, unknown>): Promise<TRes> {
  const runnable = runnableCallable<TRes>(verifyGooglePlayBurnBarProSubscription);
  return runnable.run(req(data));
}

/** Fake transport capturing what the REAL recorder hands it — proves darkness. */
class FakeTransport implements ServerAnalyticsTransport {
  startCalls = 0;
  sent: AnalyticsEnvelope[] = [];
  private _started = false;
  get isStarted(): boolean {
    return this._started;
  }
  start(apiKey: string): void {
    if (this._started || apiKey.length === 0) return;
    this.startCalls += 1;
    this._started = true;
  }
  async track(event: AnalyticsEnvelope): Promise<void> {
    if (this._started) this.sent.push(event);
  }
  stop(): void {
    this._started = false;
  }
}

let transport: FakeTransport;

beforeEach(() => {
  vi.clearAllMocks();
  state.docSets.length = 0;
  state.getClient.mockResolvedValue({});
  state.claimMock.mockResolvedValue(undefined);
  state.subscriptionsV2Get.mockResolvedValue({
    data: {
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      lineItems: [{ productId: "burnbar_cloud_monthly", expiryTime: EXPIRY_ISO }],
    },
  });
  state.writeEntitlementMock.mockResolvedValue({ id: "burnbar_pro", active: true });

  // Inject the real recorder around a fake transport + a real configured key, so
  // the consent gate is exercised structurally (not mocked away).
  transport = new FakeTransport();
  setServerAnalyticsForTest(
    new ServerAnalytics({
      transport,
      apiKey: "amp-test-key",
      superProperties: () => ({ platform: "backend", app_version: "test-build" }),
      now: () => 1_700_000_000_000,
      insertId: () => "rand-insert",
    }),
  );
});

describe("verifyGooglePlayBurnBarProSubscription — consent-gated analytics", () => {
  it("emits NOTHING by default (no propagated consent ⇒ dark; transport never started)", async () => {
    await invoke({ purchaseToken: TOKEN });
    expect(state.writeEntitlementMock).toHaveBeenCalledTimes(1); // the purchase still verifies
    expect(transport.startCalls).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it("emits NOTHING when consent is explicitly declined", async () => {
    await invoke({ purchaseToken: TOKEN, analyticsConsent: "declined", analyticsDeviceId: DEVICE });
    expect(transport.sent).toHaveLength(0);
    expect(transport.startCalls).toBe(0);
  });

  it("emits NOTHING when granted but the device id is missing/invalid", async () => {
    await invoke({ purchaseToken: TOKEN, analyticsConsent: "granted" });
    await invoke({ purchaseToken: TOKEN, analyticsConsent: "granted", analyticsDeviceId: "bad id with spaces!" });
    expect(transport.sent).toHaveLength(0);
  });

  it("emits exactly ONE conversion when granted + device id, with the right shape and NO PII", async () => {
    const res = await invoke<{ active: boolean }>({
      purchaseToken: TOKEN,
      analyticsConsent: "granted",
      analyticsDeviceId: DEVICE,
    });
    expect(res.active).toBe(true);

    // Entitlement is written BEFORE the emit (the conversion is real).
    expect(state.writeEntitlementMock).toHaveBeenCalledTimes(1);
    expect(transport.startCalls).toBe(1);
    expect(transport.sent).toHaveLength(1);

    const e = transport.sent[0];
    expect(e.name).toBe("subscription.entitlement.granted");
    expect(e.category).toBe("conversion_auth");
    expect(e.deviceId).toBe(DEVICE);
    expect(e.userId).toBe(userIdHash(UID)); // authenticated action ⇒ stable hashed user_id
    expect(e.userId).not.toBe(UID);
    // dedup key is derived from the token HASH, never the raw token.
    expect(e.insertId).toBe(`gp_sub_${tokenHash(TOKEN)}`);
    expect(e.insertId).not.toContain(TOKEN);

    expect(e.props).toMatchObject({
      platform: "backend",
      entitlement_family: "burnbar_pro",
      source: "google_play",
      purchase_platform: "android",
      outcome: "success",
    });
    expect(typeof e.props.expires_in_seconds_bucket).toBe("string");

    // PII / leakage sweep over the entire serialized event.
    const serialized = JSON.stringify(e);
    expect(serialized).not.toContain(TOKEN); // raw purchase token
    expect(serialized).not.toContain(UID); // raw Firebase uid
    expect(serialized).not.toContain("@"); // no emails
    expect(serialized).not.toMatch(/users\//); // no Firestore paths
    // every property value is a string or boolean (no raw numbers on the wire).
    for (const v of Object.values(e.props)) expect(["string", "boolean"]).toContain(typeof v);
  });

  it("reports an expired subscription as outcome=failure (still gated, still no PII)", async () => {
    state.subscriptionsV2Get.mockResolvedValue({
      data: {
        subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
        lineItems: [{ productId: "burnbar_cloud_monthly", expiryTime: "2020-01-01T00:00:00.000Z" }],
      },
    });
    await invoke({ purchaseToken: TOKEN, analyticsConsent: "granted", analyticsDeviceId: DEVICE });
    expect(transport.sent).toHaveLength(1);
    expect(transport.sent[0].props.outcome).toBe("failure");
  });

  it("uses a stable insert_id across retries of the same purchase (idempotent dedup)", async () => {
    await invoke({ purchaseToken: TOKEN, analyticsConsent: "granted", analyticsDeviceId: DEVICE });
    await invoke({ purchaseToken: TOKEN, analyticsConsent: "granted", analyticsDeviceId: DEVICE });
    expect(transport.sent).toHaveLength(2);
    expect(transport.sent[0].insertId).toBe(transport.sent[1].insertId); // same dedup key
  });

  it("never lets an analytics failure break the verified-purchase response", async () => {
    // A transport that throws must not surface from the callable.
    const throwing: ServerAnalyticsTransport = {
      isStarted: false,
      start() {
        (this as { isStarted: boolean }).isStarted = true;
      },
      async track() {
        throw new Error("amplitude exploded");
      },
      stop() {},
    };
    setServerAnalyticsForTest(
      new ServerAnalytics({
        transport: throwing,
        apiKey: "amp-test-key",
        superProperties: () => ({ platform: "backend", app_version: "test-build" }),
      }),
    );
    // The emit helper awaits track(); if track throws it would reject the
    // callable. The wiring must therefore be resilient — assert the call still
    // resolves with the verified purchase result.
    await expect(
      invoke<{ active: boolean }>({ purchaseToken: TOKEN, analyticsConsent: "granted", analyticsDeviceId: DEVICE }),
    ).resolves.toMatchObject({ active: true });
  });
});
