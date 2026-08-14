import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { callableRunner, pathKeyedFirestore, requireDoc, requireEntry } from "./bola/callableBolaHarness.js";

const TEST_IP = "203.0.113.10";
const TEST_UID = "voter-uid-001";
const OTHER_UID = "voter-uid-002";

/**
 * Instrumentation for the bounded-read proof.
 *
 * `matchupDocs` counts every arena_matchups document the handler actually
 * pulls, and `lastProjection` records the field list it asked for — the two
 * facts A3 is about (how many, and how much of each).
 */
interface RegistryReadCounters {
  matchupDocs: number;
  lastProjection: string[] | undefined;
}

const mocks = vi.hoisted(() => {
  const reads: RegistryReadCounters = { matchupDocs: 0, lastProjection: undefined };
  return { store: new Map<string, Record<string, unknown>>(), reads };
});

interface MatchupQuery {
  startAt: (cursor: string) => MatchupQuery;
  select: (...fields: string[]) => MatchupQuery;
  limit: (n: number) => MatchupQuery;
  get: () => Promise<{ docs: Array<{ id: string; data: () => Record<string, unknown> }>; empty: boolean }>;
}

/**
 * An id-ordered, cursor-paged, projecting query over arena_matchups.
 *
 * The shared harness fake treats `limit`/`select`/`orderBy` as no-ops, which
 * would let an unbounded full-collection read pass a test silently. This one
 * honours them (and `startAt`) so "the handler reads at most N documents" is a
 * claim the suite can actually check, and so the projection genuinely strips
 * the identity columns the serving path must never see.
 */
function idOrderedMatchupQuery(
  store: Map<string, Record<string, unknown>>,
  counters: RegistryReadCounters,
  options: { startAt?: string; limit?: number; fields?: string[] } = {},
): MatchupQuery {
  return {
    startAt: (cursor) => idOrderedMatchupQuery(store, counters, { ...options, startAt: cursor }),
    select: (...fields) => idOrderedMatchupQuery(store, counters, { ...options, fields }),
    limit: (n) => idOrderedMatchupQuery(store, counters, { ...options, limit: n }),
    get: async () => {
      const prefix = "arena_matchups/";
      let entries = [...store.entries()]
        .filter(([key]) => key.startsWith(prefix) && !key.slice(prefix.length).includes("/"))
        .map(([key, value]) => [key.slice(prefix.length), value] as const)
        .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
      const startAt = options.startAt;
      if (startAt !== undefined) entries = entries.filter(([id]) => id >= startAt);
      if (options.limit !== undefined) entries = entries.slice(0, options.limit);
      counters.matchupDocs += entries.length;
      counters.lastProjection = options.fields;
      const docs = entries.map(([id, data]) => {
        const projected = options.fields
          ? Object.fromEntries(options.fields.filter((field) => field in data).map((field) => [field, data[field]]))
          : data;
        return { id, data: () => projected, get: (field: string) => projected[field], exists: true };
      });
      return { docs, empty: docs.length === 0 };
    },
  };
}

/** The harness fake, with a faithful arena_matchups query and read counting. */
function arenaFirestore(store: Map<string, Record<string, unknown>>, counters: RegistryReadCounters) {
  const base = pathKeyedFirestore(store);
  return {
    ...base,
    collection: (name: string) => {
      const collection = base.collection(name);
      if (name !== "arena_matchups") return collection;
      return {
        ...collection,
        // Counted so an unbounded `.collection().get()` cannot pass the bound.
        get: async () => {
          const snapshot = await collection.get();
          counters.matchupDocs += snapshot.docs.length;
          counters.lastProjection = undefined;
          return snapshot;
        },
        orderBy: () => idOrderedMatchupQuery(store, counters),
      };
    },
  };
}

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return { ...actual, getFirestore: () => arenaFirestore(mocks.store, mocks.reads) };
});
vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));

import { arenaMatchup, arenaVote } from "../arenaVote.js";

const run = callableRunner(arenaVote);
const runMatchup = callableRunner(arenaMatchup);

const MATCHUP_ID = "m-abc123";

interface MatchupResult {
  matchupId: string;
  serveId: string;
  left: { bundleId: string; entry: string };
  right: { bundleId: string; entry: string };
}

interface CompetitorReveal {
  harness: string;
}

interface VoteResult {
  voteId: string;
  reveal: { left: CompetitorReveal; right: CompetitorReveal };
}

function seedMatchup(store: Map<string, Record<string, unknown>>): void {
  store.set(`arena_matchups/${MATCHUP_ID}`, {
    matchup_id: MATCHUP_ID,
    left_bundle_id: "bundle-left-sha",
    right_bundle_id: "bundle-right-sha",
    left_entry: "scene.svg",
    right_entry: "index.html",
    task_id: "40_svg_scene",
    left_cell: "droid/gpt-5-6-luna-max/40_svg_scene/trial-01",
    right_cell: "pi/deepseek-v4-flash-0731/40_svg_scene/trial-01",
    order: "AB",
  });
}

function seedSecondMatchup(store: Map<string, Record<string, unknown>>): void {
  store.set("arena_matchups/m-def456", {
    matchup_id: "m-def456",
    left_bundle_id: "bundle-l2",
    right_bundle_id: "bundle-r2",
    left_entry: "index.html",
    right_entry: "index.html",
    task_id: "44_product_viewer",
    left_cell: "droid/claude-opus-4/44_product_viewer/trial-01",
    right_cell: "pi/gpt-5/44_product_viewer/trial-01",
    order: "AB",
  });
}

/** Seed an extra matchup so a caller can cast another (deduped) vote. */
function seedExtraMatchup(matchupId: string): void {
  mocks.store.set(`arena_matchups/${matchupId}`, {
    matchup_id: matchupId,
    left_bundle_id: "bl",
    right_bundle_id: "br",
    left_entry: "index.html",
    right_entry: "index.html",
    task_id: "t",
    left_cell: `d-${matchupId}/m/t/trial-01`,
    right_cell: `p-${matchupId}/m/t/trial-01`,
    order: "AB",
  });
}

let serveCounter = 0;

interface SeedServeOptions {
  serveId?: string;
  matchupId?: string;
  servedSwap?: boolean;
  servedToUid?: string | null;
  consumedBy?: string | null;
  expiresInMs?: number;
}

/**
 * Write a serve ticket exactly as `arenaMatchup` would.
 *
 * Tests that are not about matchup serving mint their ballots here so they do
 * not have to guess the server's coin flip — the orientation under test is
 * stated explicitly, which is the whole point of it living server-side.
 */
function seedServe(options: SeedServeOptions = {}): string {
  serveCounter += 1;
  const serveId = options.serveId ?? `serve-${serveCounter}`;
  mocks.store.set(`arena_serves/${serveId}`, {
    schema_version: 1,
    serve_id: serveId,
    matchup_id: options.matchupId ?? MATCHUP_ID,
    served_swap: options.servedSwap ?? false,
    served_to_uid: options.servedToUid === undefined ? null : options.servedToUid,
    consumed_by_uid: options.consumedBy ?? null,
    served_at_utc: new Date().toISOString(),
    expires_at_millis: Date.now() + (options.expiresInMs ?? 60_000),
  });
  return serveId;
}

function validPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const matchupId = typeof overrides.matchupId === "string" ? overrides.matchupId : MATCHUP_ID;
  return { schemaVersion: 1, matchupId, serveId: seedServe({ matchupId }), choice: "A", ...overrides };
}

/** Authenticated vote request with a Firebase Auth uid. */
function voteRequest(data: Record<string, unknown>, uid?: string, ip?: string, xff?: string): unknown {
  return {
    auth: uid === undefined ? { uid: TEST_UID, token: {} } : { uid, token: {} },
    rawRequest: {
      headers: xff === undefined ? {} : { "x-forwarded-for": xff },
      ...(ip === undefined ? {} : { ip }),
    },
    data,
  };
}

/** Anonymous (no auth) request — for matchup serving and unauth vote tests. */
function anonRequest(data: Record<string, unknown>, ip?: string): unknown {
  return { rawRequest: { headers: {}, ...(ip === undefined ? {} : { ip }) }, data };
}

function castVote<Result = unknown>(
  data: Record<string, unknown>,
  uid = TEST_UID,
  ip = TEST_IP,
  xff?: string,
): Promise<Result> {
  return run(voteRequest(data, uid, ip, xff));
}

/** A ballot payload naming an explicit serve ticket. */
function ballot(serveId: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { schemaVersion: 1, matchupId: MATCHUP_ID, serveId, choice: "A", ...overrides };
}

function voteDocs(): Array<[string, Record<string, unknown>]> {
  return [...mocks.store.entries()].filter(([key]) => key.startsWith("arena_votes/"));
}

function onlyVote(): Record<string, unknown> {
  return requireEntry(voteDocs())[1];
}

function serveDoc(serveId: string): Record<string, unknown> | undefined {
  return mocks.store.get(`arena_serves/${serveId}`);
}

beforeEach(() => {
  mocks.store.clear();
  mocks.reads.matchupDocs = 0;
  mocks.reads.lastProjection = undefined;
  seedMatchup(mocks.store);
});

describe("arenaVote — auth", () => {
  it("rejects a vote without Firebase Auth", async () => {
    await expect(run(anonRequest(validPayload(), TEST_IP))).rejects.toMatchObject({ code: "unauthenticated" });
    expect(voteDocs()).toHaveLength(0);
  });

  it("writes the vote and reveals identities only after the write", async () => {
    const result = await castVote<VoteResult>(validPayload());
    expect(typeof result.voteId).toBe("string");
    expect(result.voteId.length).toBeGreaterThan(0);
    expect(result.reveal.left.harness).toBe("droid");
    expect(result.reveal.right.harness).toBe("pi");

    const docs = voteDocs();
    expect(docs).toHaveLength(1);
    const [docId, vote] = requireEntry(docs);
    expect(docId).toBe(`arena_votes/${TEST_UID}__${MATCHUP_ID}`);
    expect(vote.vote_id).toBe(result.voteId);
    expect(vote.voter_uid).toBe(TEST_UID);
    expect(vote.matchup_id).toBe(MATCHUP_ID);
    expect(vote.choice).toBe("A");
    expect(vote.task_id).toBe("40_svg_scene");
    expect(vote.left_cell).toBe("droid/gpt-5-6-luna-max/40_svg_scene/trial-01");
    expect(vote.right_cell).toBe("pi/deepseek-v4-flash-0731/40_svg_scene/trial-01");
    // IP is never stored on the vote document.
    expect(JSON.stringify(vote)).not.toContain(TEST_IP);
  });

  it("rejects a duplicate vote from the same uid on the same matchup", async () => {
    await castVote(validPayload({ choice: "A" }));
    await expect(castVote(validPayload({ choice: "B" }))).rejects.toMatchObject({ code: "already-exists" });
    // Only one vote document exists for this uid+matchup.
    expect(voteDocs()).toHaveLength(1);
  });

  it("allows different uids to vote on the same matchup", async () => {
    await castVote(validPayload({ choice: "A" }));
    await castVote(validPayload({ choice: "B" }), OTHER_UID);
    expect(voteDocs()).toHaveLength(2);
    const ids = voteDocs()
      .map(([id]) => id)
      .sort();
    expect(ids).toEqual([`arena_votes/${OTHER_UID}__${MATCHUP_ID}`, `arena_votes/${TEST_UID}__${MATCHUP_ID}`].sort());
  });

  it("rejects a matchupId containing a slash (doc-id safety)", async () => {
    await expect(castVote(validPayload({ matchupId: "evil/path" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects a serveId containing a slash (doc-id safety)", async () => {
    await expect(castVote(validPayload({ serveId: "evil/path" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(voteDocs()).toHaveLength(0);
  });
});

describe("arenaVote — data integrity", () => {
  it("defaults voter to anonymous and records optional why", async () => {
    await castVote(validPayload({ why: "cleaner composition" }));
    expect(onlyVote().voter).toBe("anonymous");
    expect(onlyVote().why).toBe("cleaner composition");
  });

  it("normalizes the choice when the matchup was served swapped", async () => {
    await castVote(ballot(seedServe({ servedSwap: true })));
    const vote = onlyVote();
    expect(vote.choice).toBe("B"); // flipped to stored orientation
    expect(vote.served_swap).toBe(true);
    expect(vote.left_cell).toBe("droid/gpt-5-6-luna-max/40_svg_scene/trial-01");
    expect(vote.right_cell).toBe("pi/deepseek-v4-flash-0731/40_svg_scene/trial-01");
  });

  it("keeps the choice when not served swapped", async () => {
    await castVote(ballot(seedServe({ servedSwap: false })));
    expect(onlyVote().choice).toBe("A");
    expect(onlyVote().served_swap).toBe(false);
  });

  it("rejects an unknown matchupId and writes nothing", async () => {
    await expect(castVote(validPayload({ matchupId: "nope" }))).rejects.toMatchObject({ code: "not-found" });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects an invalid choice", async () => {
    await expect(castVote(validPayload({ choice: "skip" }))).rejects.toMatchObject({ code: "invalid-argument" });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects unexpected fields", async () => {
    await expect(castVote(validPayload({ hacker: "x" }))).rejects.toMatchObject({ code: "invalid-argument" });
  });

  it("rejects an oversized why", async () => {
    await expect(castVote(validPayload({ why: "x".repeat(2000) }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
  });

  it("rejects a vote with no serveId at all", async () => {
    const { serveId: _dropped, ...withoutServe } = validPayload();
    void _dropped;
    await expect(castVote(withoutServe)).rejects.toMatchObject({ code: "invalid-argument" });
    expect(voteDocs()).toHaveLength(0);
  });
});

/**
 * A2 — the orientation binding.
 *
 * The choice→cell mapping IS the vote, so these tests exist to prove the
 * server never takes the client's word for it.
 */
describe("arenaVote — server-authoritative orientation", () => {
  it("ignores a client-supplied servedSwap that contradicts the served orientation", async () => {
    // The client claims the pairing was NOT swapped. The server showed it swapped.
    await castVote(ballot(seedServe({ servedSwap: true }), { servedSwap: false }));
    const vote = onlyVote();
    expect(vote.served_swap).toBe(true);
    // "A" on screen was the stored RIGHT cell, so the recorded pick is "B".
    expect(vote.choice).toBe("B");
  });

  it("ignores a client-supplied servedSwap claiming a swap that never happened", async () => {
    await castVote(ballot(seedServe({ servedSwap: false }), { servedSwap: true }));
    expect(onlyVote().served_swap).toBe(false);
    expect(onlyVote().choice).toBe("A");
  });

  it("ignores a client-supplied servedSwap when flipping rubric verdicts", async () => {
    const payload = ballot(seedServe({ servedSwap: true }), {
      servedSwap: false,
      dimensions: { visual_polish: "A", accessibility: "tie" },
    });
    await castVote(payload);
    expect(onlyVote().dimensions).toEqual({ visual_polish: "B", accessibility: "tie" });
  });

  // Each case is a distinct route by which a caller could try to assert an
  // orientation of its own choosing.
  const forgeryCases: Array<{ name: string; code: string; serve: () => string }> = [
    {
      name: "a ballot issued for a different matchup",
      code: "permission-denied",
      serve: () => {
        seedSecondMatchup(mocks.store);
        return seedServe({ matchupId: "m-def456", servedSwap: true });
      },
    },
    {
      name: "a ballot issued to a different signed-in voter",
      code: "permission-denied",
      serve: () => seedServe({ servedToUid: OTHER_UID }),
    },
    { name: "a fabricated serveId", code: "failed-precondition", serve: () => "not-a-real-ballot" },
    { name: "an expired ballot", code: "failed-precondition", serve: () => seedServe({ expiresInMs: -1_000 }) },
    {
      name: "an already-consumed ballot",
      code: "failed-precondition",
      serve: () => seedServe({ consumedBy: OTHER_UID }),
    },
    {
      name: "a ballot with a malformed orientation rather than guessing",
      code: "internal",
      serve: () => {
        const serveId = seedServe();
        mocks.store.set(`arena_serves/${serveId}`, {
          ...requireDoc(mocks.store, `arena_serves/${serveId}`),
          served_swap: "yes",
        });
        return serveId;
      },
    },
  ];

  for (const forgery of forgeryCases) {
    it(`rejects ${forgery.name}`, async () => {
      await expect(castVote(ballot(forgery.serve()))).rejects.toMatchObject({ code: forgery.code });
      expect(voteDocs()).toHaveLength(0);
    });
  }

  it("consumes the ballot so an anonymous one cannot be replayed by a second voter", async () => {
    const serveId = seedServe({ servedToUid: null });
    await castVote(ballot(serveId));
    expect(serveDoc(serveId)?.consumed_by_uid).toBe(TEST_UID);
    // A different uid: the one-vote-per-uid dedup would NOT stop this, the
    // single-use ticket does.
    await expect(castVote(ballot(serveId, { choice: "B" }), OTHER_UID)).rejects.toMatchObject({
      code: "failed-precondition",
    });
    expect(voteDocs()).toHaveLength(1);
  });

  it("maps the voter's on-screen pick to the cell that actually produced it", async () => {
    // End to end through the real serving path, whichever way the server's coin
    // lands: a vote for the artifact on the left must be recorded against the
    // cell whose bundle was displayed on the left.
    const served = await runMatchup<MatchupResult>(anonRequest({ schemaVersion: 1 }, "203.0.113.60"));
    await castVote({ schemaVersion: 1, matchupId: served.matchupId, serveId: served.serveId, choice: "A" });
    const vote = onlyVote();
    const leftWasStoredLeft = served.left.bundleId === "bundle-left-sha";
    expect(vote.choice).toBe(leftWasStoredLeft ? "A" : "B");
    expect(vote.served_swap).toBe(!leftWasStoredLeft);
    expect(vote.serve_id).toBe(served.serveId);
  });
});

/** A1 — the reveal stays a reward for judging, not a lookup API. */
describe("arenaVote — reveal is bounded, bound, and non-enumerable", () => {
  it("reveals identities in the orientation the voter actually saw", async () => {
    const result = await castVote<VoteResult>(ballot(seedServe({ servedSwap: true })));
    // Served swapped: the stored RIGHT cell was on the voter's left.
    expect(result.reveal.left.harness).toBe("pi");
    expect(result.reveal.right.harness).toBe("droid");
  });

  it("cannot be used to look up a matchup the caller was never served", async () => {
    seedSecondMatchup(mocks.store);
    // A ticket for m-abc123 cannot be pointed at m-def456 to read its identities.
    const payload = ballot(seedServe({ matchupId: MATCHUP_ID }), { matchupId: "m-def456", choice: "tie" });
    await expect(castVote(payload)).rejects.toMatchObject({ code: "permission-denied" });
    expect(voteDocs()).toHaveLength(0);
  });

  it("cannot reveal the same pairing twice to one identity", async () => {
    await castVote(validPayload({ choice: "tie" }));
    // A fresh, valid ballot for the same pairing still yields no second reveal.
    await expect(castVote(validPayload({ choice: "tie" }))).rejects.toMatchObject({ code: "already-exists" });
  });

  it("cannot be used to enumerate identities in bulk by rotating IPs", async () => {
    const revealed = new Set<string>();
    // The per-uid burst ceiling is 12/min. Every call comes from a different
    // client address, which under an IP-keyed limit would buy 12 fresh buckets.
    for (let i = 0; i < 12; i += 1) {
      seedExtraMatchup(`m-harvest-${i}`);
      const payload = validPayload({ matchupId: `m-harvest-${i}`, choice: "tie" });
      const result = await castVote<VoteResult>(payload, TEST_UID, `198.51.100.${i + 1}`);
      revealed.add(result.reveal.left.harness);
    }
    expect(revealed.size).toBe(12);

    seedExtraMatchup("m-harvest-12");
    const beyond = validPayload({ matchupId: "m-harvest-12", choice: "tie" });
    await expect(castVote(beyond, TEST_UID, "198.51.100.200")).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    // Nothing beyond the 12 paid-for judgments was written or revealed.
    expect(voteDocs()).toHaveLength(12);
  });
});

describe("arenaVote — rubric dimensions", () => {
  it("persists a full rubric alongside the overall choice", async () => {
    const dimensions = {
      visual_polish: "A",
      interaction_quality: "B",
      accessibility: "tie",
      code_quality: "A",
    };
    await castVote(validPayload({ choice: "A", dimensions }));
    expect(onlyVote().choice).toBe("A");
    expect(onlyVote().dimensions).toEqual(dimensions);
  });

  it("persists a partial rubric — skipped axes are absent, not tied", async () => {
    await castVote(validPayload({ choice: "B", dimensions: { accessibility: "A" } }));
    expect(onlyVote().dimensions).toEqual({ accessibility: "A" });
  });

  it("writes dimensions:null when the voter skips the rubric entirely", async () => {
    await castVote(validPayload({ choice: "A" }));
    expect(onlyVote().dimensions).toBeNull();
    // Everything else is exactly the pre-rubric vote document.
    expect(onlyVote().choice).toBe("A");
    expect(onlyVote().why).toBeNull();
  });

  it("treats an empty rubric object as no rubric at all", async () => {
    await castVote(validPayload({ choice: "A", dimensions: {} }));
    expect(onlyVote().dimensions).toBeNull();
  });

  it("flips rubric verdicts with the overall choice when served swapped", async () => {
    const payload = ballot(seedServe({ servedSwap: true }), {
      dimensions: { visual_polish: "A", interaction_quality: "B", accessibility: "tie" },
    });
    await castVote(payload);
    expect(onlyVote().choice).toBe("B");
    expect(onlyVote().dimensions).toEqual({
      visual_polish: "B",
      interaction_quality: "A",
      accessibility: "tie",
    });
  });

  it("rejects an unknown dimension key and writes nothing", async () => {
    await expect(castVote(validPayload({ dimensions: { vibes: "A" } }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects an unknown dimension key even when paired with a valid one", async () => {
    const payload = validPayload({ dimensions: { visual_polish: "A", vibes: "B" } });
    await expect(castVote(payload)).rejects.toMatchObject({ code: "invalid-argument" });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects an invalid dimension verdict and writes nothing", async () => {
    await expect(castVote(validPayload({ dimensions: { visual_polish: "skip" } }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects a non-string dimension verdict", async () => {
    await expect(castVote(validPayload({ dimensions: { visual_polish: 1 } }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects a non-object dimensions payload", async () => {
    await expect(castVote(validPayload({ dimensions: "visual_polish" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    await expect(castVote(validPayload({ dimensions: ["visual_polish"] }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(voteDocs()).toHaveLength(0);
  });

  it("rejects a prototype-pollution key like any other undeclared key", async () => {
    const payload = validPayload({ dimensions: JSON.parse('{"__proto__":"A"}') });
    await expect(castVote(payload)).rejects.toMatchObject({ code: "invalid-argument" });
    expect(voteDocs()).toHaveLength(0);
  });

  it("still reveals identities only after the rubric vote commits", async () => {
    const result = await castVote<VoteResult>(validPayload({ dimensions: { code_quality: "B" } }));
    expect(result.reveal.left.harness).toBe("droid");
    expect(onlyVote().vote_id).toBe(result.voteId);
  });
});

/**
 * A4 — the limit follows the account, because that is the thing a ballot
 * stuffer cannot mint for free.
 */
describe("arenaVote — rate limiting", () => {
  afterEach(() => {
    delete process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR;
  });

  async function burnBurst(prefix: string, uid: string, ip: (i: number) => string, xff?: string): Promise<void> {
    for (let i = 0; i < 12; i += 1) {
      seedExtraMatchup(`${prefix}-${i}`);
      await castVote(validPayload({ matchupId: `${prefix}-${i}` }), uid, ip(i), xff);
    }
  }

  it("rate-limits a burst per uid even when every request comes from a new IP", async () => {
    await burnBurst("m-burst", TEST_UID, (i) => `192.0.2.${i + 1}`);
    seedExtraMatchup("m-burst-12");
    const beyond = validPayload({ matchupId: "m-burst-12" });
    await expect(castVote(beyond, TEST_UID, "192.0.2.250")).rejects.toMatchObject({ code: "resource-exhausted" });
    expect(voteDocs()).toHaveLength(12);
  });

  it("does not let one exhausted voter block another sharing the same address", async () => {
    await burnBurst("m-shared", TEST_UID, () => TEST_IP);
    await expect(castVote(validPayload())).rejects.toMatchObject({ code: "resource-exhausted" });
    // Same IP, different account: unaffected. An IP-keyed primary would have
    // thrown here too, which is the "one NAT, one voter" failure mode.
    await castVote(validPayload(), OTHER_UID);
    expect(voteDocs()).toHaveLength(13);
  });

  it("ignores a caller-written X-Forwarded-For for the secondary bound", async () => {
    process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR = "1";
    // A single-hop chain is indistinguishable from a forged one, so it must not
    // become a rate-limit bucket at all — and the uid bound still applies.
    await burnBurst("m-xff", TEST_UID, () => TEST_IP, "10.0.0.7");
    seedExtraMatchup("m-xff-12");
    const beyond = validPayload({ matchupId: "m-xff-12" });
    await expect(castVote(beyond, TEST_UID, TEST_IP, "10.0.0.99")).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    expect([...mocks.store.keys()].filter((key) => key.includes("arena_vote_ip_"))).toHaveLength(0);
  });

  it("applies the secondary IP bound only on a trusted multi-hop chain", async () => {
    process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR = "1";
    // "<forged>, <real client>, <load balancer>" — the real client is second
    // from the right; everything to its left is caller-written.
    await castVote(validPayload(), TEST_UID, TEST_IP, "1.2.3.4, 198.51.100.7, 130.211.0.1");
    expect([...mocks.store.keys()].filter((key) => key.includes("arena_vote_ip_"))).toHaveLength(2);
  });
});

describe("arenaMatchup — anonymous serving", () => {
  it("returns anonymized bundles and no identities without auth", async () => {
    const result = await runMatchup<MatchupResult>(anonRequest({ schemaVersion: 1 }, "203.0.113.99"));
    expect(result.matchupId).toBe(MATCHUP_ID);
    for (const secret of ["droid", "deepseek", "trial-01"]) expect(JSON.stringify(result)).not.toContain(secret);
    expect([result.left.bundleId, result.right.bundleId].sort()).toEqual(["bundle-left-sha", "bundle-right-sha"]);
    const entryByBundle = new Map([
      [result.left.bundleId, result.left.entry],
      [result.right.bundleId, result.right.entry],
    ]);
    expect(entryByBundle.get("bundle-left-sha")).toBe("scene.svg");
    expect(entryByBundle.get("bundle-right-sha")).toBe("index.html");
  });

  it("persists the served orientation and never discloses it to the caller", async () => {
    const anon96 = anonRequest({ schemaVersion: 1 }, "203.0.113.96");
    const result = await runMatchup<MatchupResult & Record<string, unknown>>(anon96);
    expect(typeof result.serveId).toBe("string");
    expect(result.serveId.length).toBeGreaterThan(0);
    expect("servedSwap" in result).toBe(false);
    expect(JSON.stringify(result)).not.toContain("servedSwap");

    const serve = requireDoc(mocks.store, `arena_serves/${result.serveId}`);
    expect(serve.matchup_id).toBe(MATCHUP_ID);
    expect(typeof serve.served_swap).toBe("boolean");
    expect(serve.served_to_uid).toBeNull();
    expect(serve.consumed_by_uid).toBeNull();
    expect(Number(serve.expires_at_millis)).toBeGreaterThan(Date.now());
    // The recorded orientation matches what was actually laid out.
    expect(serve.served_swap).toBe(result.left.bundleId === "bundle-right-sha");
  });

  it("binds the ballot to the uid it was issued to when the caller is signed in", async () => {
    const result = await runMatchup<MatchupResult>(voteRequest({ schemaVersion: 1 }, TEST_UID, "203.0.113.93"));
    expect(serveDoc(result.serveId)?.served_to_uid).toBe(TEST_UID);
  });

  it("reads a bounded slice of the registry rather than the whole thing", async () => {
    for (let i = 0; i < 300; i += 1) seedExtraMatchup(`m-bulk-${String(i).padStart(4, "0")}`);
    mocks.reads.matchupDocs = 0;
    const result = await runMatchup<MatchupResult>(anonRequest({ schemaVersion: 1 }, "203.0.113.92"));
    expect(typeof result.matchupId).toBe("string");
    expect(mocks.reads.matchupDocs).toBeGreaterThan(0);
    // At most two pages of 12; the registry has 301 entries.
    expect(mocks.reads.matchupDocs).toBeLessThanOrEqual(24);
  });

  it("never loads the competitor identity columns on the serving path", async () => {
    await runMatchup(anonRequest({ schemaVersion: 1 }, "203.0.113.91"));
    expect(mocks.reads.lastProjection).toBeDefined();
    expect(mocks.reads.lastProjection).not.toContain("left_cell");
    expect(mocks.reads.lastProjection).not.toContain("right_cell");
    expect(mocks.reads.lastProjection).toContain("left_bundle_id");
  });

  it("sanitizes malformed registry entry paths to index.html", async () => {
    mocks.store.set(`arena_matchups/${MATCHUP_ID}`, {
      ...requireDoc(mocks.store, `arena_matchups/${MATCHUP_ID}`),
      left_entry: "../escape.html",
      right_entry: "https://evil.com/x.html",
    });
    const result = await runMatchup<MatchupResult>(anonRequest({ schemaVersion: 1 }, "203.0.113.97"));
    expect(result.left.entry).toBe("index.html");
    expect(result.right.entry).toBe("index.html");
  });

  it("fails closed when no matchups are published", async () => {
    mocks.store.clear();
    await expect(runMatchup(anonRequest({ schemaVersion: 1 }, "203.0.113.98"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });
});

describe("arenaMatchup — authed exclusion", () => {
  it("excludes matchups the signed-in voter already judged", async () => {
    seedSecondMatchup(mocks.store);
    // Vote on the first matchup as TEST_UID.
    await castVote(validPayload({ choice: "A" }));
    // Now request a matchup as TEST_UID — must get the second (unvoted) one.
    const result = await runMatchup<{ matchupId: string }>(voteRequest({ schemaVersion: 1 }, TEST_UID, "203.0.113.95"));
    expect(result.matchupId).toBe("m-def456");
  });

  it("fails when the signed-in voter has judged every published pairing", async () => {
    await castVote(validPayload({ choice: "A" }));
    await expect(runMatchup(voteRequest({ schemaVersion: 1 }, TEST_UID, "203.0.113.94"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });
});
