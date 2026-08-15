import { beforeEach, describe, expect, it, vi } from "vitest";

const remoteConfigState = vi.hoisted((): { template: unknown; fail: boolean } => ({
  template: undefined,
  fail: false,
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({
    memoryBoostText1mProductID: "com.openburnbar.memory.boost.text.1m",
    memoryBoostText5mProductID: "com.openburnbar.memory.boost.text.5m",
    memoryBoostVision1mProductID: "com.openburnbar.memory.boost.vision.1m",
    googlePlayMemoryBoostText1mProductID: "com.openburnbar.memory.boost.text.1m",
    googlePlayMemoryBoostText5mProductID: "com.openburnbar.memory.boost.text.5m",
    googlePlayMemoryBoostVision1mProductID: "com.openburnbar.memory.boost.vision.1m",
    stripeMemoryBoostText1mPriceID: "price_text_1m",
    stripeMemoryBoostText5mPriceID: "price_text_5m",
    stripeMemoryBoostVision1mPriceID: "price_vision_1m",
  }),
}));

vi.mock("firebase-admin/remote-config", () => ({
  getRemoteConfig: () => ({
    getTemplate: async () => {
      if (remoteConfigState.fail) throw new Error("rc down");
      return remoteConfigState.template;
    },
  }),
}));

vi.mock("../logging.js", () => ({
  logWarn: vi.fn(),
}));

import {
  DEFAULT_MEMORY_PACKS,
  defaultMemoryPack,
  isMemoryLane,
  isMemoryPackId,
  isMemoryPackProductID,
  memoryPackFromAppleProductID,
  memoryPackFromPlayProductID,
  memoryPackFromStripePriceID,
  memoryPackRuntimeIds,
} from "../usageCuration/catalog.js";
import {
  isMemoryPackOffered,
  listedMemoryPacks,
  loadMemoryPackCatalog,
  normalizeMemoryPackCatalog,
} from "../usageCuration/remoteConfig.js";

describe("Memory Boost catalog", () => {
  it("recognizes pack ids, lanes, and store product ids", () => {
    expect(isMemoryPackId("text_1m")).toBe(true);
    expect(isMemoryPackId("nope")).toBe(false);
    expect(isMemoryLane("multimodal")).toBe(true);
    expect(isMemoryLane("vision")).toBe(false);
    expect(defaultMemoryPack("text_5m")).toBe(DEFAULT_MEMORY_PACKS.text_5m);
    expect(isMemoryPackProductID("com.openburnbar.memory.boost.text.1m")).toBe(true);
    expect(isMemoryPackProductID("com.openburnbar.pro.monthly")).toBe(false);
  });

  it("maps Apple, Play, and Stripe identifiers onto catalog packs", () => {
    expect(memoryPackFromAppleProductID("com.openburnbar.memory.boost.text.5m")).toBe("text_5m");
    expect(memoryPackFromPlayProductID("com.openburnbar.memory.boost.vision.1m")).toBe("vision_1m");
    expect(memoryPackFromStripePriceID("price_text_1m")).toBe("text_1m");
    expect(memoryPackFromStripePriceID("")).toBeUndefined();
    expect(memoryPackFromAppleProductID("unknown")).toBeUndefined();
    expect(memoryPackRuntimeIds("text_1m").stripePriceID).toBe("price_text_1m");
    expect(memoryPackRuntimeIds("text_5m").playProductID).toBe("com.openburnbar.memory.boost.text.5m");
    expect(memoryPackRuntimeIds("vision_1m").appleProductID).toBe("com.openburnbar.memory.boost.vision.1m");
  });
});

describe("Memory Boost remote config overlay", () => {
  beforeEach(() => {
    remoteConfigState.fail = false;
    remoteConfigState.template = undefined;
  });

  it("hides packs, raises floors, and ignores token-size overlays", () => {
    const catalog = normalizeMemoryPackCatalog({
      text_1m: { hidden: true, minChargeMinor: 50, tokens: 9_999_999 },
      text_5m: { minChargeMinor: 900 },
      vision_1m: "not-an-object",
    });
    expect(isMemoryPackOffered(catalog.packs.text_1m)).toBe(false);
    expect(catalog.packs.text_1m.tokens).toBe(1_000_000);
    expect(catalog.packs.text_1m.minChargeMinor).toBe(200);
    expect(catalog.packs.text_5m.minChargeMinor).toBe(900);
    expect(catalog.packs.vision_1m).toEqual(DEFAULT_MEMORY_PACKS.vision_1m);
    expect(listedMemoryPacks(catalog, false).map((pack) => pack.packId)).toEqual(["text_5m"]);
    expect(listedMemoryPacks(catalog, true).map((pack) => pack.packId)).toEqual(["text_5m", "vision_1m"]);
  });

  it("loads the Remote Config overlay and falls back when RC is unavailable", async () => {
    remoteConfigState.template = {
      parameters: {
        memory_pack_catalog: {
          defaultValue: { value: JSON.stringify({ vision_1m: { hidden: true } }) },
        },
      },
    };
    const hidden = await loadMemoryPackCatalog();
    expect(isMemoryPackOffered(hidden.packs.vision_1m)).toBe(false);

    remoteConfigState.template = {
      parameters: {
        memory_pack_catalog: { defaultValue: { value: "not-json" } },
      },
    };
    const invalid = await loadMemoryPackCatalog();
    expect(invalid.packs.text_1m.title).toBe(DEFAULT_MEMORY_PACKS.text_1m.title);

    remoteConfigState.fail = true;
    const fallback = await loadMemoryPackCatalog();
    expect(fallback.packs.vision_1m.title).toBe(DEFAULT_MEMORY_PACKS.vision_1m.title);
  });
});
