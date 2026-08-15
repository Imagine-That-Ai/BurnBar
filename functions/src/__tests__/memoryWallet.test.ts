import { beforeEach, describe, expect, it, vi } from "vitest";

type StoredDoc = Record<string, unknown>;

interface DocRef {
  path: string;
  collection(name: string): CollectionRef;
  get(): Promise<DocSnapshot>;
}

interface CollectionRef {
  path: string;
  doc(id: string): DocRef;
  get(): Promise<{ docs: Array<{ id: string; data(): StoredDoc | undefined; ref: DocRef }> }>;
}

interface DocSnapshot {
  exists: boolean;
  data(): StoredDoc | undefined;
  get(field: string): unknown;
}

const { dbMock, store } = vi.hoisted(() => {
  const docs = new Map<string, StoredDoc>();

  const snapshotFor = (path: string): DocSnapshot => ({
    exists: docs.has(path),
    data: () => docs.get(path),
    get: (field: string) => docs.get(path)?.[field],
  });

  const applySet = (path: string, data: StoredDoc, options?: { merge?: boolean }) => {
    const existing = options?.merge === true ? { ...(docs.get(path) ?? {}) } : {};
    docs.set(path, { ...existing, ...data });
  };

  const childDocs = (prefix: string) => {
    const needle = `${prefix}/`;
    return [...docs.entries()].filter(([path]) => {
      if (!path.startsWith(needle)) return false;
      return !path.slice(needle.length).includes("/");
    });
  };

  const doc = (path: string): DocRef => ({
    path,
    collection: (name: string) => collection(`${path}/${name}`),
    get: async () => snapshotFor(path),
  });

  const collection = (path: string): CollectionRef => ({
    path,
    doc: (id: string) => doc(`${path}/${id}`),
    get: async () => ({
      docs: childDocs(path).map(([childPath, data]) => ({
        id: childPath.slice(path.length + 1),
        data: () => data,
        ref: doc(childPath),
      })),
    }),
  });

  const db = {
    doc,
    collection,
    runTransaction: async <T>(fn: (transaction: unknown) => Promise<T>): Promise<T> => {
      const txn = {
        get: async (ref: DocRef | CollectionRef) => {
          if ("collection" in ref && typeof ref.collection === "function" && "path" in ref) {
            const asDoc = ref as DocRef;
            if (typeof asDoc.get === "function" && !("doc" in ref)) {
              return snapshotFor(asDoc.path);
            }
          }
          if ("doc" in ref) {
            return (ref as CollectionRef).get();
          }
          return snapshotFor((ref as DocRef).path);
        },
        set: (ref: DocRef, data: StoredDoc, options?: { merge?: boolean }) => {
          applySet(ref.path, data, options);
        },
      };
      return fn(txn);
    },
  };

  return { dbMock: db, store: docs };
});

vi.mock("firebase-admin/firestore", () => {
  class FakeTimestamp {
    constructor(readonly millis: number) {}
    toMillis() {
      return this.millis;
    }
    static now() {
      return new FakeTimestamp(Date.now());
    }
    static fromMillis(millis: number) {
      return new FakeTimestamp(millis);
    }
  }
  return { Timestamp: FakeTimestamp };
});

vi.mock("../adminRuntime.js", () => ({
  db: dbMock,
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

import {
  MemoryWalletInsufficientError,
  debitWallet,
  getWalletBalances,
  grantMemoryPack,
  reverseMemoryPackGrant,
  settlePendingMemoryPacks,
} from "../usageCuration/wallet.js";
import { db } from "../adminRuntime.js";
import {
  listedMemoryPacks,
  normalizeMemoryPackCatalog,
  isMemoryPackOffered,
} from "../usageCuration/remoteConfig.js";
import { Timestamp } from "firebase-admin/firestore";

const UID = "user_memory_wallet";

describe("memory wallet", () => {
  beforeEach(() => {
    store.clear();
  });

  it("credits a text pack and debit is FIFO by expiry", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "txn_a",
      packId: "text_1m",
      visionEligible: false,
    });
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "txn_b",
      packId: "text_5m",
      visionEligible: false,
    });

    await db.runTransaction(async (txn) => {
      const balances = await debitWallet(txn, UID, "text", 1_200_000, "res_1");
      expect(balances.textTokens).toBe(4_800_000);
      return balances;
    });

    const first = store.get(`users/${UID}/memoryWallet/current/grants/stripe_txn_a`);
    const second = store.get(`users/${UID}/memoryWallet/current/grants/stripe_txn_b`);
    expect(first?.spentTokens).toBe(1_000_000);
    expect(first?.status).toBe("exhausted");
    expect(second?.spentTokens).toBe(200_000);
    expect(second?.remainingTokens).toBe(4_800_000);
  });

  it("replays the same reservationId without a second debit", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "app_store",
      transactionId: "txn_replay",
      packId: "text_1m",
      visionEligible: true,
    });
    await db.runTransaction(async (txn) => debitWallet(txn, UID, "text", 100, "same-res"));
    await db.runTransaction(async (txn) => debitWallet(txn, UID, "text", 100, "same-res"));
    const grant = store.get(`users/${UID}/memoryWallet/current/grants/app_store_txn_replay`);
    expect(grant?.spentTokens).toBe(100);
  });

  it("refunds only the remaining tokens of the refunded grant", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "pack_a",
      packId: "text_1m",
      visionEligible: false,
      amountMinor: 299,
    });
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "pack_b",
      packId: "text_1m",
      visionEligible: false,
      amountMinor: 299,
    });
    await db.runTransaction(async (txn) => debitWallet(txn, UID, "text", 400_000, "spend_a"));

    const result = await reverseMemoryPackGrant({
      uid: UID,
      source: "stripe",
      transactionId: "pack_a",
      fullReversal: true,
    });
    expect(result.clawedBack).toBe(600_000);

    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.textTokens).toBe(1_000_000);
      return balances;
    });
    const untouched = store.get(`users/${UID}/memoryWallet/current/grants/stripe_pack_b`);
    expect(untouched?.remainingTokens).toBe(1_000_000);
    expect(untouched?.status).toBe("active");
  });

  it("holds vision packs pending until Cloud Pro is present", async () => {
    const first = await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "vision_1",
      packId: "vision_1m",
      visionEligible: false,
    });
    expect(first.pending).toBe(true);
    expect(first.granted).toBe(false);
    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.multimodalTokens).toBe(0);
      return balances;
    });
    expect(store.get(`users/${UID}/memoryWallet/current`)?.pendingMultimodalTokens).toBe(1_000_000);
    expect(store.get(`users/${UID}/memoryWallet/current`)?.multimodalTokens).toBe(0);

    expect(await settlePendingMemoryPacks(UID, false)).toBe(0);
    expect(await settlePendingMemoryPacks(UID, true)).toBe(1);
    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.multimodalTokens).toBe(1_000_000);
      return balances;
    });
  });

  it("throws MemoryWalletInsufficientError instead of HttpsError", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "google_play",
      transactionId: "small",
      packId: "text_1m",
      visionEligible: true,
    });
    await expect(
      db.runTransaction(async (txn) => debitWallet(txn, UID, "text", 2_000_000, "too-big")),
    ).rejects.toBeInstanceOf(MemoryWalletInsufficientError);
  });

  it("throws when a refund arrives before the grant exists", async () => {
    await expect(
      reverseMemoryPackGrant({
        uid: UID,
        source: "stripe",
        transactionId: "missing",
        fullReversal: true,
      }),
    ).rejects.toThrow("memory_pack_grant_missing");
  });

  it("grant replay is idempotent", async () => {
    const first = await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "dup",
      packId: "text_1m",
      visionEligible: true,
    });
    const second = await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "dup",
      packId: "text_1m",
      visionEligible: true,
    });
    expect(first.alreadyGranted).toBe(false);
    expect(second.alreadyGranted).toBe(true);
    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.textTokens).toBe(1_000_000);
      return balances;
    });
  });

  it("expires pending vision packs so settle cannot revive them after TTL", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "pending_ttl",
      packId: "vision_1m",
      visionEligible: false,
    });
    const grantPath = [...store.keys()].find((path) => path.includes("/grants/"));
    expect(grantPath).toBeTruthy();
    const grant = store.get(grantPath!);
    grant!.expiresAt = { toMillis: () => Date.now() - 1000 };
    expect(await settlePendingMemoryPacks(UID, true)).toBe(0);
    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.multimodalTokens).toBe(0);
      return balances;
    });
  });

  it("Apple-style refund clawback restores only refundReversedTokens", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "app_store",
      transactionId: "apple_refund",
      packId: "text_1m",
      visionEligible: true,
    });
    await reverseMemoryPackGrant({
      uid: UID,
      source: "app_store",
      transactionId: "apple_refund",
      refundFull: true,
    });
    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.textTokens).toBe(0);
      return balances;
    });
    await reverseMemoryPackGrant({
      uid: UID,
      source: "app_store",
      transactionId: "apple_refund",
      restoreRefund: true,
    });
    await db.runTransaction(async (txn) => {
      const balances = await getWalletBalances(txn, UID);
      expect(balances.textTokens).toBe(1_000_000);
      return balances;
    });
  });
});

describe("memory pack remote config overlay", () => {
  it("cannot lower floors or inflate token sizes", () => {
    const catalog = normalizeMemoryPackCatalog({
      text_1m: { tokens: 9_000_000, minChargeMinor: 1, hidden: false },
      vision_1m: { hidden: true },
    });
    expect(catalog.packs.text_1m.tokens).toBe(1_000_000);
    expect(catalog.packs.text_1m.minChargeMinor).toBe(200);
    expect(catalog.packs.vision_1m.title).toBe("");
    expect(isMemoryPackOffered(catalog.packs.vision_1m)).toBe(false);
    expect(listedMemoryPacks(catalog, true).map((pack) => pack.packId)).toEqual(["text_1m", "text_5m"]);
    expect(listedMemoryPacks(normalizeMemoryPackCatalog(undefined), false).map((pack) => pack.packId)).toEqual([
      "text_1m",
      "text_5m",
    ]);
  });
});

describe("memory wallet grant mechanics", () => {
  beforeEach(() => {
    store.clear();
  });

  it("debits the grant that expires first even when it was created later", async () => {
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "created_first_expires_later",
      packId: "text_1m",
      visionEligible: true,
    });
    await grantMemoryPack({
      uid: UID,
      source: "stripe",
      transactionId: "created_second_expires_sooner",
      packId: "text_1m",
      visionEligible: true,
    });
    const later = store.get(`users/${UID}/memoryWallet/current/grants/stripe_created_first_expires_later`);
    const sooner = store.get(`users/${UID}/memoryWallet/current/grants/stripe_created_second_expires_sooner`);
    later!.expiresAt = Timestamp.fromMillis(Date.now() + 40 * 24 * 60 * 60 * 1000);
    sooner!.expiresAt = Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000);

    await db.runTransaction(async (txn) => debitWallet(txn, UID, "text", 1, "fifo_expiry"));
    expect(store.get(`users/${UID}/memoryWallet/current/grants/stripe_created_second_expires_sooner`)?.spentTokens).toBe(1);
    expect(store.get(`users/${UID}/memoryWallet/current/grants/stripe_created_first_expires_later`)?.spentTokens).toBe(0);
  });

  it("refuses a 401st live grant", async () => {
    const now = { toMillis: () => Date.now() + 30 * 24 * 60 * 60 * 1000 };
    for (let index = 0; index < 400; index += 1) {
      store.set(`users/${UID}/memoryWallet/current/grants/stripe_cap_${index}`, {
        type: "grant",
        status: "active",
        source: "stripe",
        transactionId: `cap_${index}`,
        packId: "text_1m",
        lane: "text",
        tokens: 1,
        spentTokens: 0,
        remainingTokens: 1,
        refundReversedTokens: 0,
        disputeReversedTokens: 0,
        reversedTokens: 0,
        expiresAt: now,
        createdAt: now,
        updatedAt: now,
      });
    }
    await expect(
      grantMemoryPack({
        uid: UID,
        source: "stripe",
        transactionId: "cap_overflow",
        packId: "text_1m",
        visionEligible: true,
      }),
    ).rejects.toThrow(/grant cap/);
  });
});
