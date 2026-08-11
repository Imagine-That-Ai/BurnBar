import { beforeAll, describe, it, expect, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/**
 * Governance for the Arena's client↔callable contract: the optional
 * per-dimension rubric, and the vote wire itself.
 *
 * The rubric vocabulary is declared in three places that must agree exactly:
 *
 *   1. `functions/src/arenaVote.ts`   — the write path. It validates
 *      fail-closed, so an axis the server has not declared is not "ignored",
 *      it rejects the whole vote with `invalid-argument`.
 *   2. `website/src/scripts/bench-arena.ts` — the submitter.
 *   3. `website/src/pages/bench/arena/vote.astro` — the controls a voter sees.
 *
 * (A fourth copy lives in `runner/arena_schema.py` in the bench repo, which is
 * out of this repo's reach; its own tests pin the same tuple.)
 *
 * Drift between 1 and 2/3 is the dangerous direction: the page would render a
 * control whose every use produces a rejected vote, and the voter would be
 * told their judgment "could not be recorded" with no way to tell why. These
 * tests make that a build failure instead of a production incident.
 *
 * The second half of this file governs the orientation contract, which has the
 * same shape of risk and worse consequences. Orientation moved server-side:
 * `arenaMatchup` flips a coin, records it against an opaque `serveId`, and
 * serves both the pairing AND (later) the reveal in that served orientation.
 * The client must therefore send the ticket and apply no flip of its own. Both
 * halves of that are silent when wrong — a re-swapping client mislabels the
 * reveal on exactly the half of matchups that were served swapped, and nothing
 * in the UI looks broken — so they are pinned here.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const REPO = join(ROOT, "..");

const CALLABLE = join(REPO, "functions", "src", "arenaVote.ts");
const CLIENT = join(ROOT, "src", "scripts", "bench-arena.ts");
const PAGE = join(ROOT, "src", "pages", "bench", "arena", "vote.astro");

/** Pull the string literals out of a `const ARENA_DIMENSIONS = [...] as const`. */
function declaredDimensions(file: string): string[] {
  const source = readFileSync(file, "utf8");
  const block = /const ARENA_DIMENSIONS = \[([\s\S]*?)\] as const;/.exec(source);
  if (!block) throw new Error(`no ARENA_DIMENSIONS declaration in ${file}`);
  return [...block[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
}

/** The `data-dimension` keys the vote page renders, in document order. */
function pageDimensions(): string[] {
  const source = readFileSync(PAGE, "utf8");
  const rows = /class="bb-arena__rubric-rows"([\s\S]*?)<\/div>\s*<\/form>/.exec(source);
  if (!rows) throw new Error("no rubric rows block in vote.astro");
  return [...rows[1].matchAll(/key:\s*"([a-z_]+)"/g)].map((m) => m[1]);
}

describe("Arena rubric vocabulary is identical everywhere it is declared", () => {
  const server = declaredDimensions(CALLABLE);

  it("the callable declares a non-trivial closed vocabulary", () => {
    expect(server.length).toBeGreaterThan(1);
    expect(server).toContain("visual_polish");
    expect(new Set(server).size).toBe(server.length);
  });

  it("the client submitter declares the same axes in the same order", () => {
    expect(declaredDimensions(CLIENT)).toEqual(server);
  });

  it("the vote page renders one row per axis, in the same order", () => {
    expect(pageDimensions()).toEqual(server);
  });
});

describe("Arena rubric stays optional and additive", () => {
  it("the callable declares dimensions as an optional field", () => {
    const source = readFileSync(CALLABLE, "utf8");
    // optionalEnumRecordField parses absent / null / {} to undefined, which is
    // what keeps a rubric-free vote byte-identical to the pre-rubric wire.
    expect(source).toMatch(/dimensions:\s*optionalEnumRecordField\(/);
    // The overall pick is still a required enum — the rubric never replaces it.
    expect(source).toMatch(/choice:\s*enumField\(ARENA_CHOICES/);
  });

  it("the client omits the field entirely when the rubric is untouched", () => {
    const source = readFileSync(CLIENT, "utf8");
    expect(source).toContain("...(dimensions ? { dimensions } : {})");
  });

  it("every rubric row offers exactly A / tie / B and starts unset", () => {
    const source = readFileSync(PAGE, "utf8");
    const values = [...source.matchAll(/\{ value: "(A|tie|B)", label:/g)].map((m) => m[1]);
    expect(values).toEqual(["A", "tie", "B"]);
    // No pre-selected verdict: a voter who ignores the block sends nothing.
    expect(source).not.toMatch(/class="bb-arena__rubric-input"[\s\S]{0,200}?checked/);
  });

  it("the rows are a labelled radiogroup, not a bare div", () => {
    const source = readFileSync(PAGE, "utf8");
    expect(source).toContain('role="radiogroup"');
    expect(source).toMatch(/aria-labelledby=\{`rubric-label-\$\{dimension\.key\}`\}/);
  });
});

/* =====================================================================
 * The vote wire: serve tickets, orientation, and failure recovery.
 *
 * These exercise the real functions out of bench-arena.ts rather than its
 * source text. That module is a page script — it boots itself — so the import
 * below is set up to give us its pure exports without booting anything: every
 * dependency is stubbed, and `document.readyState = "loading"` parks `wire()`
 * on a DOMContentLoaded event that never fires in this environment.
 * ===================================================================== */

vi.mock("firebase/app", () => ({
  getApp: () => ({ name: "arena-public" }),
  getApps: () => [],
  initializeApp: (_config: unknown, name?: string) => ({ name }),
}));

vi.mock("firebase/functions", () => ({
  getFunctions: () => ({}),
  // The callables are never invoked here; only the pure request builder and
  // the failure classifier are under test.
  httpsCallable: () => async () => ({ data: {} }),
}));

vi.mock("firebase/auth", () => {
  class StubProvider {
    addScope(): this {
      return this;
    }
  }
  return {
    GoogleAuthProvider: StubProvider,
    GithubAuthProvider: StubProvider,
    FacebookAuthProvider: StubProvider,
    OAuthProvider: StubProvider,
    getAuth: () => ({}),
    signInWithPopup: async () => ({}),
    signInWithRedirect: async () => ({}),
    getRedirectResult: async () => null,
    onAuthStateChanged: () => () => {},
    signOut: async () => {},
  };
});

vi.mock("../src/lib/firebaseClient", () => ({
  firebaseConfig: { projectId: "burnbar-test", apiKey: "test", authDomain: "test" },
}));
vi.mock("../src/lib/analytics", () => ({ EVENT: {}, trackEvent: () => {} }));
vi.mock("../src/scripts/arena-tasks", () => ({
  arenaTaskBrief: () => ({ title: "", brief: "", judgeOn: [] }),
}));
vi.mock("../src/scripts/arena-identities", () => ({ buildIdentityCard: () => ({}) }));
vi.mock("../src/scripts/arena-net", () => ({ initArenaNet: () => {} }));

type ArenaModule = typeof import("../src/scripts/bench-arena");
let arena: ArenaModule;

beforeAll(async () => {
  Object.assign(globalThis, {
    document: {
      documentElement: { dataset: {} },
      readyState: "loading",
      addEventListener: () => {},
    },
    location: { hostname: "burnbar.ai", search: "" },
  });
  arena = await import("../src/scripts/bench-arena");
});

/** A rejection shaped like the Firebase SDK's: code on `code`, prose on `message`. */
function callableError(code: string, message: string): Error {
  return Object.assign(new Error(message), { code: `functions/${code}` });
}

/**
 * A stand-in for the server's coin flip.
 *
 * The client never learns `swap`; these helpers exist to prove the client is
 * correct for BOTH values of a bit it cannot see. `arenaMatchup` applies the
 * flip to the bundles it serves, and `arenaVote` applies the same flip to the
 * reveal — so a correct client applies none.
 */
const STORED = {
  left: {
    bundle: { bundleId: "bundle-droid", entry: "index.html" },
    identity: { harness: "droid", model: "gpt-5", task: "experiential", trial: 1 },
  },
  right: {
    bundle: { bundleId: "bundle-codex", entry: "index.html" },
    identity: { harness: "codex", model: "glm-5-2", task: "experiential", trial: 2 },
  },
};

function serveMatchup(swap: boolean) {
  return {
    matchupId: "matchup-1",
    serveId: "serve-1",
    task: "experiential",
    left: swap ? STORED.right.bundle : STORED.left.bundle,
    right: swap ? STORED.left.bundle : STORED.right.bundle,
  };
}

function serveReveal(swap: boolean) {
  return {
    left: swap ? STORED.right.identity : STORED.left.identity,
    right: swap ? STORED.left.identity : STORED.right.identity,
  };
}

describe("the vote wire sends the serve ticket, never a claimed orientation", () => {
  it("every vote carries serveId", () => {
    const payload = arena.buildVotePayload(
      { matchupId: "matchup-1", serveId: "serve-1" },
      "A",
      undefined,
    );
    expect(payload.serveId).toBe("serve-1");
    expect(payload.matchupId).toBe("matchup-1");
    expect(payload.choice).toBe("A");
    expect(payload.schemaVersion).toBe(1);
  });

  it("no vote carries servedSwap — the client has no orientation to assert", () => {
    for (const choice of ["A", "B", "tie"] as const) {
      const bare = arena.buildVotePayload({ matchupId: "m", serveId: "s" }, choice, undefined);
      const scored = arena.buildVotePayload({ matchupId: "m", serveId: "s" }, choice, {
        visual_polish: "A",
      });
      expect(Object.keys(bare)).not.toContain("servedSwap");
      expect(Object.keys(scored)).not.toContain("servedSwap");
    }
  });

  it("an untouched rubric leaves the field off the wire entirely", () => {
    const payload = arena.buildVotePayload({ matchupId: "m", serveId: "s" }, "tie", undefined);
    expect(Object.keys(payload).sort()).toEqual(["choice", "matchupId", "schemaVersion", "serveId"]);
  });

  it("a scored rubric rides along unmodified", () => {
    const payload = arena.buildVotePayload({ matchupId: "m", serveId: "s" }, "B", {
      visual_polish: "A",
      code_quality: "tie",
    });
    expect(payload.dimensions).toEqual({ visual_polish: "A", code_quality: "tie" });
  });

  it("the callable requires serveId and only tolerates servedSwap", () => {
    const source = readFileSync(CALLABLE, "utf8");
    // Required on the wire: omitting it is invalid-argument, so a client that
    // forgot it would fail every vote.
    expect(source).toMatch(/serveId:\s*requiredString\(/);
    // Accepted so an in-flight old tab is not hard-failed...
    expect(source).toMatch(/servedSwap:\s*optionalBooleanField\(/);
    // ...but never read: the parsed input type must not carry it.
    const parsed = /interface ArenaVoteInput \{([\s\S]*?)\}/.exec(source);
    expect(parsed).not.toBeNull();
    expect(parsed![1]).toContain("serveId: string;");
    expect(parsed![1]).not.toContain("servedSwap");
  });

  it("the client's matchup type mirrors what arenaMatchup actually returns", () => {
    const source = readFileSync(CLIENT, "utf8");
    const shape = /interface MatchupResponse \{([\s\S]*?)\n\}/.exec(source);
    expect(shape).not.toBeNull();
    expect(shape![1]).toContain("serveId: string;");
    // The server stopped sending it; a client field declaring otherwise would
    // be a lie the type checker happily accepts.
    expect(shape![1]).not.toContain("servedSwap");
    const serverResponse = /export const arenaMatchup = onCallProduction[\s\S]*$/.exec(
      readFileSync(CALLABLE, "utf8"),
    );
    expect(serverResponse![0]).toContain("serveId,");
    expect(serverResponse![0]).not.toMatch(/return \{[\s\S]*servedSwap[,:]/);
  });
});

describe("A and B mean the same thing in the frames and in the reveal", () => {
  for (const swap of [false, true]) {
    it(`labels the right competitor when the server ${swap ? "swapped" : "did not swap"}`, () => {
      const panes = arena.servedSides(serveMatchup(swap));
      const cards = arena.servedSides(serveReveal(swap));
      // The bundle in pane A must belong to the stack named on card A. The
      // bundle ids are tagged with their harness precisely so this is checkable
      // from the outside, the way a voter would check it.
      expect(panes.a.bundleId).toBe(`bundle-${cards.a.harness}`);
      expect(panes.b.bundleId).toBe(`bundle-${cards.b.harness}`);
      expect(cards.a.harness).not.toBe(cards.b.harness);
    });
  }

  it("serves the pair exactly as received — the identity map, both ways round", () => {
    for (const swap of [false, true]) {
      const served = serveMatchup(swap);
      expect(arena.servedSides(served).a).toBe(served.left);
      expect(arena.servedSides(served).b).toBe(served.right);
    }
  });

  it("re-swapping the reveal would mislabel every swapped matchup (the bug this prevents)", () => {
    // The pre-serve-ticket client flipped the reveal when it believed the
    // matchup was swapped. Against a reveal that already arrives in served
    // orientation that is a double swap: pane A would show droid's artifact
    // while card A credited codex. Unswapped matchups looked fine, which is
    // why it survived — so pin the failure explicitly.
    const panes = arena.servedSides(serveMatchup(true));
    const reSwapped = arena.servedSides({ left: serveReveal(true).right, right: serveReveal(true).left });
    expect(panes.a.bundleId).not.toBe(`bundle-${reSwapped.a.harness}`);
  });
});

describe("callable failures are classified by error.code, not by prose", () => {
  it("reads the code off `code` and strips the SDK namespace", () => {
    expect(arena.callableErrorCode(callableError("already-exists", "You already judged this pairing."))).toBe(
      "already-exists",
    );
    expect(arena.callableErrorCode(callableError("permission-denied", "nope"))).toBe("permission-denied");
  });

  it("returns nothing for a rejection that carries no code", () => {
    expect(arena.callableErrorCode(new Error("failed-precondition"))).toBe("");
    expect(arena.callableErrorCode(null)).toBe("");
    expect(arena.callableErrorCode(undefined)).toBe("");
    expect(arena.callableErrorCode("failed-precondition")).toBe("");
  });

  it("the old message sniffing could never have matched — that was the bug", () => {
    // These are the server's actual sentences. None of them contains its code,
    // so `err.message.includes("already-exists")` was dead code in both places
    // it appeared: duplicate votes and expired ballots fell through to the
    // generic "please retry", which for both of them is advice that cannot work.
    const duplicate = callableError("already-exists", "You already judged this pairing.");
    const expired = callableError(
      "failed-precondition",
      "This pairing has expired. Load a fresh pairing to vote.",
    );
    expect(duplicate.message).not.toContain("already-exists");
    expect(expired.message).not.toContain("failed-precondition");
    // Read the code instead and both are recognised.
    expect(arena.isStaleBallot(duplicate)).toBe(true);
    expect(arena.isStaleBallot(expired)).toBe(true);
  });

  it("treats every ballot-level rejection as spent", () => {
    for (const code of ["failed-precondition", "permission-denied", "already-exists", "not-found"]) {
      expect(arena.isStaleBallot(callableError(code, "…"))).toBe(true);
    }
    for (const code of ["unauthenticated", "resource-exhausted", "internal", "invalid-argument"]) {
      expect(arena.isStaleBallot(callableError(code, "…"))).toBe(false);
    }
  });

  it("covers every non-internal code the serve-ticket check can raise", () => {
    // Drift guard: if the callable learns a new way to reject a ballot, the
    // client must learn to recover from it rather than dead-end the voter.
    const source = readFileSync(CALLABLE, "utf8");
    const fn = /async function resolveServedOrientation\([\s\S]*?\n\}/.exec(source);
    expect(fn).not.toBeNull();
    const codes = [...fn![0].matchAll(/new HttpsError\("([a-z-]+)"/g)].map((m) => m[1]);
    expect(codes.length).toBeGreaterThan(3);
    for (const code of codes) {
      // `internal` is a server fault (a corrupt ticket), not a spent ballot:
      // re-dealing would paper over a registry bug, so it stays an error.
      if (code === "internal") continue;
      expect(arena.isStaleBallot(callableError(code, "…"))).toBe(true);
    }
  });
});

describe("a dead ballot deals a fresh pairing instead of a dead end", () => {
  for (const code of ["failed-precondition", "permission-denied", "already-exists", "not-found"]) {
    it(`${code} refetches`, () => {
      const action = arena.voteFailureAction(callableError(code, "…"));
      expect(action.kind).toBe("refetch");
      // The voter is told why the pairing changed under them.
      expect(action.kind === "refetch" && action.status.length).toBeGreaterThan(0);
    });
  }

  it("distinguishes the reasons in the copy", () => {
    const of = (code: string): string => {
      const action = arena.voteFailureAction(callableError(code, "…"));
      return action.kind === "refetch" ? action.status : "";
    };
    const messages = new Set([
      of("failed-precondition"),
      of("permission-denied"),
      of("already-exists"),
      of("not-found"),
    ]);
    expect(messages.size).toBe(4);
  });

  it("a lapsed session re-opens the sign-in gate instead of refetching", () => {
    expect(arena.voteFailureAction(callableError("unauthenticated", "…")).kind).toBe("reauth");
  });

  it("a rate limit or a server fault just reports", () => {
    for (const code of ["resource-exhausted", "internal", "deadline-exceeded", "unavailable"]) {
      expect(arena.voteFailureAction(callableError(code, "…")).kind).toBe("status");
    }
  });

  it("the vote path actually acts on the refetch decision", () => {
    // The decision is pure and tested above; this pins the one line of wiring
    // that turns it into a fresh pairing — and that the reason is carried into
    // loadMatchup, whose first statement overwrites the status line, so a
    // setStatus() before the call would show the voter nothing at all.
    const source = readFileSync(CLIENT, "utf8");
    expect(source).toMatch(/action\.kind === "refetch"[\s\S]{0,500}?void loadMatchup\(action\.status\);/);
    expect(source).toMatch(/action\.kind === "reauth"[\s\S]{0,500}?openAuthGate\(\);/);
    expect(source).toMatch(/async function loadMatchup\(reason\?: string\)[\s\S]{0,120}?setStatus\(reason \?\? /);
  });

  it("a failed serve surfaces the server's own sentence, not a guess", () => {
    // arenaMatchup raises failed-precondition for an empty registry AND for a
    // voter who has judged everything; the previous client asserted the former
    // for both, so a prolific voter was told the Arena was empty.
    expect(
      arena.matchupFailureMessage(
        callableError("failed-precondition", "You've judged every pairing we can offer right now."),
      ),
    ).toBe("You've judged every pairing we can offer right now.");
    expect(arena.matchupFailureMessage(callableError("failed-precondition", ""))).toContain(
      "No Arena matchups are published yet",
    );
    expect(arena.matchupFailureMessage(callableError("resource-exhausted", "…"))).toMatch(/moment/i);
    expect(arena.matchupFailureMessage(new Error("boom"))).toMatch(/Could not load a matchup/);
  });
});
