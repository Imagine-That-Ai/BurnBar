/**
 * Regression: pending-delta queue for the usage counter pipeline
 * (crosscut-011).
 *
 * The trigger used to apply counter deltas synchronously — a transaction of
 * up to 11-21 sets per usage event, all write-locking the user's shared
 * day/all_time bucket docs (plus their provider/account/model/device
 * subdocs). Session-end sync bursts commit up to 400 events at once, so the
 * transactions serialized, exhausted retries, recorded `lastErrorCode`, and
 * forced the next scheduled pass into a destructive full rebuild.
 *
 * The queue model appends one immutable pending-delta doc per event and lets
 * the 5-minute worker drain pages with coalesced increments. These tests
 * cover the PURE core (`buildPendingCounterDelta`, `planPendingDeltaDrain`,
 * doc-ID ordering, payload validation); the Firestore I/O shell is exercised
 * end-to-end by scripts/test-rollups.mjs, including equivalence against the
 * reference `applyUsageCounterDelta` implementation.
 */
import { describe, expect, it } from "vitest";

import {
  buildPendingCounterDelta,
  isPendingCounterDelta,
  pendingCounterDeltaDocID,
  planPendingDeltaDrain,
  type PendingCounterDelta,
  type UsageCounterCandidate,
} from "../rollups.js";
import type { UsageEventDoc } from "../types.js";

const T0 = "2026-06-09T00:00:00.000Z";

function codexEvent(overrides: Partial<UsageEventDoc> = {}): UsageEventDoc {
  return {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId: "codex-session-1",
    model: "gpt-5.5",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    recordedAt: T0,
    startTime: T0,
    ...overrides,
  };
}

function delta(usageDoc: string, before: UsageEventDoc | undefined, after: UsageEventDoc | undefined) {
  const built = buildPendingCounterDelta(usageDoc, before, after, T0);
  if (!built) throw new Error(`expected a pending delta for ${usageDoc}`);
  return built;
}

function emptyKeyStates(): Map<string, Record<string, UsageCounterCandidate>> {
  return new Map();
}

describe("buildPendingCounterDelta", () => {
  it("returns undefined when neither side contributes (mirrors applyUsageCounterDelta's early return)", () => {
    expect(buildPendingCounterDelta("doc-1", undefined, undefined, T0)).toBeUndefined();
    // An event with no resolvable date contributes nothing.
    expect(
      buildPendingCounterDelta(
        "doc-1",
        undefined,
        { provider: "codex", schemaVersion: 1, recordedAt: "" },
        T0,
      ),
    ).toBeUndefined();
  });

  it("captures full winner-resolution data for both sides", () => {
    const before = codexEvent({ model: "unknown" });
    const after = codexEvent();
    const built = delta("doc-1", before, after);

    expect(built.candidateKey).toBe(delta("doc-1", undefined, after).candidateKey); // stable per usage doc
    expect(built.before?.modelRank).toBe(0);
    expect(built.after?.modelRank).toBe(1);
    expect(built.after?.tokens).toBe(125);
    expect(built.after?.requests).toBe(1);
    expect(built.enqueuedAt).toBe(T0);
    expect(isPendingCounterDelta(built)).toBe(true);
  });

  it("round-trips through the runtime validator and rejects corrupt payloads", () => {
    const built = delta("doc-1", undefined, codexEvent());
    expect(isPendingCounterDelta(built)).toBe(true);
    expect(isPendingCounterDelta({ ...built, after: { junk: true } })).toBe(false);
    expect(isPendingCounterDelta({ ...built, before: undefined, after: undefined })).toBe(false);
    expect(isPendingCounterDelta({ usageDoc: "x", candidateKey: "y", enqueuedAt: T0 })).toBe(false);
    expect(isPendingCounterDelta(null)).toBe(false);
  });
});

describe("pendingCounterDeltaDocID", () => {
  it("orders lexicographically by enqueue time so the implicit __name__ drain order is chronological", () => {
    const earlier = pendingCounterDeltaDocID("2026-06-09T00:00:00.000Z");
    const later = pendingCounterDeltaDocID("2026-06-09T00:00:01.000Z");
    expect(earlier < later).toBe(true);
  });

  it("is ordered and collision-free for identical timestamps", () => {
    const a = pendingCounterDeltaDocID(T0);
    const b = pendingCounterDeltaDocID(T0);
    expect(a < b).toBe(true);
    expect(a).not.toBe(b);
  });
});

describe("planPendingDeltaDrain", () => {
  it("a single create emits one positive contribution and installs the winner", () => {
    const created = delta("doc-1", undefined, codexEvent());
    const plan = planPendingDeltaDrain([created], emptyKeyStates());

    expect(plan.bucketContributions).toHaveLength(1);
    expect(plan.bucketContributions[0].requests).toBe(1);
    expect(plan.bucketContributions[0].tokens).toBe(125);
    expect(plan.keyWrites).toHaveLength(1);
    expect(plan.keyWrites[0].winner?.candidateKey).toBe(created.candidateKey);
  });

  it("coalesces a same-bucket burst into ONE merged contribution (the write-amplification fix)", () => {
    // 50 distinct usage docs from the same session burst: same provider,
    // account, model, device, and day, but different token buckets (so each
    // is its own logical key — no dedupe collapses them).
    const deltas: PendingCounterDelta[] = [];
    for (let i = 0; i < 50; i += 1) {
      const tokens = 100 + i;
      deltas.push(
        delta(`doc-${i}`, undefined, codexEvent({ inputTokens: tokens, outputTokens: 0, totalTokens: tokens })),
      );
    }

    const plan = planPendingDeltaDrain(deltas, emptyKeyStates());

    // 50 events -> one bucket-identity group: a single set per bucket doc
    // instead of 50 transactions x 11 sets.
    expect(plan.bucketContributions).toHaveLength(1);
    expect(plan.bucketContributions[0].requests).toBe(50);
    expect(plan.bucketContributions[0].tokens).toBe(50 * 100 + (49 * 50) / 2);
    expect(plan.keyWrites).toHaveLength(50);
  });

  it("replays update chains in order: B0 -> A1 -> A2 nets exactly A2 (intermediate states never emit)", () => {
    const b0 = codexEvent({ totalTokens: 100, inputTokens: 100, outputTokens: 0 });
    const a1 = codexEvent({
      totalTokens: 100,
      inputTokens: 100,
      outputTokens: 0,
      updatedAt: "2026-06-09T00:00:01.000Z",
    });
    const a2 = codexEvent({
      totalTokens: 100,
      inputTokens: 100,
      outputTokens: 0,
      updatedAt: "2026-06-09T00:00:02.000Z",
      costUsd: 0.002,
    });

    // Seed the key state as if B0 was already applied.
    const seeded = delta("doc-1", undefined, b0);
    const seededPlan = planPendingDeltaDrain([seeded], emptyKeyStates());
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of seededPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    const plan = planPendingDeltaDrain([delta("doc-1", b0, a1), delta("doc-1", a1, a2)], keyStates);

    // The final winner reflects A2 (newest updatedAt) — A1 never surfaces.
    expect(plan.keyWrites).toHaveLength(1);
    expect(plan.keyWrites[0].winner?.updatedMillis).toBe(Date.parse("2026-06-09T00:00:02.000Z"));
    // B0 and A2 share the bucket identity tuple and metrics except cost: the
    // merged -B0/+A2 increments cancel requests/tokens and carry only the
    // cost delta (0.002 - 0.001).
    expect(plan.bucketContributions).toHaveLength(1);
    expect(plan.bucketContributions[0].requests).toBe(0);
    expect(plan.bucketContributions[0].tokens).toBe(0);
    expect(plan.bucketContributions[0].costUsd).toBeCloseTo(0.001, 10);
  });

  it("dedupe winner flips across the queue: a better candidate negates the old winner and adds the new one", () => {
    const poor = codexEvent({ model: "unknown" });
    const good = codexEvent(); // same logical key (same token bucket), better modelRank

    const plan = planPendingDeltaDrain(
      [delta("doc-poor", undefined, poor), delta("doc-good", undefined, good)],
      emptyKeyStates(),
    );

    // Same bucket identity except `model`: two groups, one negative (unknown)
    // ... actually the poor candidate never WINS long enough to emit — the
    // flip coalesces to initial (none) vs final (good), so only the winner's
    // group appears.
    expect(plan.bucketContributions).toHaveLength(1);
    expect(plan.bucketContributions[0].model).toBe("gpt-5.5");
    expect(plan.bucketContributions[0].requests).toBe(1);
    expect(plan.keyWrites).toHaveLength(1);
    expect(Object.keys(plan.keyWrites[0].candidates)).toHaveLength(2);
    expect(plan.keyWrites[0].winner?.modelRank).toBe(1);
  });

  it("removing the winner falls back to the surviving candidate with a true flip (negate winner, add survivor)", () => {
    const poor = codexEvent({ model: "unknown" });
    const good = codexEvent();

    const seededPlan = planPendingDeltaDrain(
      [delta("doc-poor", undefined, poor), delta("doc-good", undefined, good)],
      emptyKeyStates(),
    );
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of seededPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    const plan = planPendingDeltaDrain([delta("doc-good", good, undefined)], keyStates);

    // Winner moves good -> poor: -good (model gpt-5.5) and +poor (model
    // unknown) are DIFFERENT bucket identities, so both groups survive.
    expect(plan.bucketContributions).toHaveLength(2);
    const negated = plan.bucketContributions.find((c) => c.model === "gpt-5.5");
    const promoted = plan.bucketContributions.find((c) => c.model === "unknown");
    expect(negated?.requests).toBe(-1);
    expect(promoted?.requests).toBe(1);
    expect(plan.keyWrites[0].winner?.modelRank).toBe(0);
  });

  it("a logical-key move negates in the old key and adds in the new key", () => {
    const original = codexEvent();
    const moved = codexEvent({ sessionId: "codex-session-moved" });

    const seededPlan = planPendingDeltaDrain([delta("doc-1", undefined, original)], emptyKeyStates());
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of seededPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    const plan = planPendingDeltaDrain([delta("doc-1", original, moved)], keyStates);

    expect(plan.keyWrites).toHaveLength(2);
    const oldKeyWrite = plan.keyWrites.find((w) => w.winner === undefined);
    const newKeyWrite = plan.keyWrites.find((w) => w.winner !== undefined);
    expect(oldKeyWrite).toBeDefined();
    expect(Object.keys(oldKeyWrite?.candidates ?? { leftover: true })).toHaveLength(0);
    expect(newKeyWrite?.winner?.candidateKey).toBe(seededPlan.keyWrites[0].winner?.candidateKey);
    // Identical bucket tuple on both sides: the -1/+1 cancel to nothing.
    expect(plan.bucketContributions).toHaveLength(0);
  });

  it("replaying an already-applied transition is a no-op (exactly-once accounting survives retries)", () => {
    const created = delta("doc-1", undefined, codexEvent());

    const firstPlan = planPendingDeltaDrain([created], emptyKeyStates());
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of firstPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    const replayPlan = planPendingDeltaDrain([created], keyStates);

    expect(replayPlan.bucketContributions).toHaveLength(0);
    expect(replayPlan.keyWrites[0].winner?.candidateKey).toBe(firstPlan.keyWrites[0].winner?.candidateKey);
  });

  it("does not mutate the caller's key states", () => {
    const existing = delta("doc-1", undefined, codexEvent());
    const seededPlan = planPendingDeltaDrain([existing], emptyKeyStates());
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of seededPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);
    const snapshot = JSON.stringify([...keyStates.entries()]);

    planPendingDeltaDrain([delta("doc-1", codexEvent(), undefined)], keyStates);

    expect(JSON.stringify([...keyStates.entries()])).toBe(snapshot);
  });
});
