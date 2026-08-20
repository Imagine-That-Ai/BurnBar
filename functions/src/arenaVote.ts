/**
 * @fileoverview BurnBench Arena vote callable.
 *
 * Records one blind pairwise human judgment for the Arena and returns the
 * reveal (which harness x model stack produced each artifact) only AFTER the
 * vote is durably written, so the reveal can never bias the judgment. This is
 * the server half of the Arena voting surface; the statistical pipeline
 * (runner/arena_ratings.py in the bench repo) consumes the mirrored votes.
 *
 * Wire contract (request):
 *   data: {
 *     schemaVersion: 1,
 *     matchupId: string,        // 1..128 chars, from the served matchup
 *     serveId: string,          // REQUIRED. Opaque ticket from arenaMatchup.
 *     choice: "A" | "B" | "tie",
 *     servedSwap?: boolean,     // DEPRECATED AND IGNORED. See "Orientation".
 *     why?: string,             // optional free-text rationale, <= 1000 chars
 *     voter?: string,           // optional pseudonymous voter id, <= 128 chars
 *     dimensions?: {            // optional rubric; each key independent of `choice`
 *       visual_polish?:       "A" | "B" | "tie",
 *       interaction_quality?: "A" | "B" | "tie",
 *       accessibility?:       "A" | "B" | "tie",
 *       code_quality?:        "A" | "B" | "tie",
 *     },
 *   }
 *
 * Wire contract (response):
 *   {
 *     voteId: string,           // server-assigned unique id for this vote
 *     reveal: {                 // in the orientation the voter SAW
 *       left:  { harness, model, task, trial },
 *       right: { harness, model, task, trial },
 *     },
 *     ranAt: ISO8601 string,
 *   }
 *
 * Orientation is server-authoritative (rating integrity, not style):
 *   - `arenaMatchup` picks the left/right orientation with a CSPRNG, writes it
 *     to a single-use serve ticket (`arena_serves/{serveId}`) alongside the
 *     matchup it was issued for, and returns only the opaque `serveId`. The
 *     orientation itself is NEVER sent to the client.
 *   - `arenaVote` reads the orientation back off that ticket. The request's
 *     `servedSwap` is parsed only so an in-flight older client is not rejected;
 *     its value is never read, and no variable in this module holds it.
 *   - Why this is load-bearing: the choice→cell mapping IS the vote. A caller
 *     that could assert its own orientation could invert the meaning of every
 *     ballot it cast — turning a vote for the artifact it liked into a vote
 *     against it — and the published Bradley-Terry ratings would faithfully
 *     record the inversion. Client-asserted orientation is not a validation
 *     problem; there is no value the client could send that the server should
 *     believe, so the field is not consulted at all.
 *   - The ticket names its matchup, so a caller cannot pair matchup X's id with
 *     matchup Y's orientation, and it is bound to the uid it was issued to when
 *     issued to a signed-in caller.
 *
 * Rubric dimensions (additive, backward compatible):
 *   - `choice` is unchanged and still required: it is the overall pick, and it
 *     remains the sole input to the published Bradley-Terry rating.
 *   - `dimensions` is an OPTIONAL map over a closed vocabulary
 *     ({@link ARENA_DIMENSIONS}) whose values use the same "A" | "B" | "tie"
 *     verdicts. A voter may fill in none, some, or all of them.
 *   - A request that omits `dimensions` (or sends `{}`) writes a document
 *     byte-identical to what this callable wrote before the field existed,
 *     apart from `dimensions: null` — so the offline sync and the ratings
 *     pipeline keep reading old and new votes with one code path.
 *   - Validation is fail-closed: an unknown dimension key, an unknown verdict,
 *     a non-string verdict, or a non-object `dimensions` rejects the whole
 *     request with `invalid-argument` and writes nothing. Partially accepting a
 *     rubric would silently drop a judgment the voter believed they cast.
 *
 * Blind-judgment integrity:
 *   - The matchup registry (arena_matchups/{matchupId}) stores the competitor
 *     identities server-side only. The vote page is served anonymized artifact
 *     bundles and learns identities exclusively through this reveal, which is
 *     returned strictly after the vote document is committed.
 *   - Votes are append-only. This function never updates or deletes a prior
 *     vote; each call writes a fresh document with a new voteId.
 *
 * Why the reveal is kept (and what stops it becoming a deanonymisation oracle):
 *   Showing a voter what they just compared is the payoff that makes anyone
 *   judge a second pairing, so deleting it would cost the Arena its throughput
 *   for no security gain the controls below do not already provide. What was
 *   actually wrong was that it was UNBOUNDED and free. It is now bounded by
 *   three independent structural facts, in order of how much work they do:
 *     1. You cannot choose what you learn. A vote is only accepted against a
 *        matchup this server itself served to this caller, proven by the serve
 *        ticket. Walking the 13k-entry registry by id is therefore impossible;
 *        the only reveals obtainable are for uniformly-random pairings.
 *     2. You cannot learn the same thing twice. `create()` on `{uid}__
 *        {matchupId}` means one vote — and so one reveal — per identity per
 *        pairing, forever, and the ticket is consumed on use.
 *     3. You cannot buy volume with headers. The rate limit is keyed on uid
 *        (see `checkArenaVoteRateLimit`), so rotating IPs buys nothing and
 *        every harvested reveal costs a real, attributable, recorded vote.
 *   And what a harvested reveal is worth is now much lower: orientation never
 *   leaves the server, so knowing "pairing M is droid×gpt-5 vs pi×deepseek"
 *   tells a second account nothing about WHICH SIDE it is being shown. A `tie`
 *   still earns its reveal: a tie is a real judgment, it is subject to all
 *   three bounds above, and taxing it would only push abusers to cast a
 *   fake preference instead — which is strictly worse for the ratings.
 *
 * Auth contract (arenaVote):
 *   - Firebase Auth required. A signed-in voter may cast exactly one vote per
 *     matchup: the vote document id is `{uid}__{matchupId}` and is written
 *     with `create()` (fails with `already-exists` if a vote already exists for
 *     that pairing). This is race-proof dedup without a transaction.
 *   - uid-keyed product-layer rate limits (`arena_vote_burst` +
 *     `arena_vote_daily`) are enforced BEFORE any write; an IP-keyed pair is a
 *     clearly-marked secondary that is inert unless the deployment can actually
 *     attribute a client address.
 *   - No App Check: the arena vote page uses a dedicated App Check-free app
 *     instance so the callable fires without a reCAPTCHA token wait.
 *
 * Auth contract (arenaMatchup):
 *   - Optional auth. A signed-in voter gets matchups they have already voted
 *     on excluded from the pick (so they never see the same pairing twice). A
 *     signed-out visitor gets the full pool (soft gate: browse freely, sign in
 *     only to vote). Rate-limited before any read, keyed on uid when signed in.
 *
 * Privacy:
 *   - The client IP is used only for rate limiting (hashed into the rate-limit
 *     doc id) and is NEVER stored on the vote document. The `voter_uid` field
 *     is the Firebase Auth uid used only for one-vote-per-matchup dedup and
 *     matchup exclusion; it is never displayed or exported to the public
 *     dashboard.
 */

import { randomBytes, randomInt, randomUUID } from "node:crypto";

import { FieldPath, FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import type { Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { checkArenaMatchupRateLimit, checkArenaVoteRateLimit } from "./callables/publicRateLimit.js";
import { assertAuth } from "./auth.js";
import { onCallProduction } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import {
  boundedInt,
  enumField,
  optionalBooleanField,
  optionalEnumRecordField,
  optionalString,
  parseCallableInput,
  requiredString,
} from "./validation/callableSchema.js";

// ---------------------------------------------------------------------------
// Wire contracts
// ---------------------------------------------------------------------------

const MAX_MATCHUP_ID_CHARS = 128;
const MAX_SERVE_ID_CHARS = 128;
const MAX_WHY_CHARS = 1000;
const MAX_VOTER_CHARS = 128;

/**
 * How long a serve ticket stays votable.
 *
 * Long enough that a voter who opens the page, gets distracted, and comes back
 * after dinner still has their vote counted; short enough that the
 * `arena_serves` collection is self-limiting. `expires_at` is written as a
 * Timestamp so a Firestore TTL policy can reap the records without a job.
 */
const ARENA_SERVE_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Hard ceiling on documents read per matchup serve.
 *
 * The registry is ~13.8k entries and growing; the previous implementation read
 * ALL of them (no `limit()`, no `select()`) on every request to a public
 * callable, which is a Firestore bill and a latency cliff waiting for traffic.
 * Selection is now a random cursor into the id-ordered registry plus a short
 * forward page, so the read cost is O(1) in the registry size.
 */
const ARENA_MATCHUP_PAGE_SIZE = 12;

/**
 * The only registry fields the serving path may read.
 *
 * `left_cell` / `right_cell` are absent BY DESIGN, not by oversight: the
 * projection makes it structurally impossible for the pre-vote surface to leak
 * competitor identities, because it never loads them in the first place.
 */
const ARENA_MATCHUP_SERVE_FIELDS = [
  "left_bundle_id",
  "right_bundle_id",
  "left_entry",
  "right_entry",
  "task_id",
] as const;

const ARENA_CHOICES = ["A", "B", "tie"] as const;
type ArenaChoice = (typeof ARENA_CHOICES)[number];

/**
 * Closed rubric vocabulary for per-dimension judgments.
 *
 * These are the axes an experiential (visual / interactive) artifact is judged
 * on beyond the overall pick. The vocabulary is mirrored in exactly two other
 * places and adding an axis is a coordinated schema change in all three:
 *   - `runner/arena_schema.py` in the bench repo (ratings + sync), and
 *   - the rubric controls in `website/src/pages/bench/arena/vote.astro`.
 * The order here is the order the voter sees.
 */
const ARENA_DIMENSIONS = ["visual_polish", "interaction_quality", "accessibility", "code_quality"] as const;
type ArenaDimension = (typeof ARENA_DIMENSIONS)[number];

/** Sparse rubric: only the axes the voter actually judged appear. */
type ArenaDimensionChoices = Partial<Record<ArenaDimension, ArenaChoice>>;

interface ArenaVoteRequest {
  schemaVersion?: number;
  matchupId?: string;
  serveId?: string;
  choice?: string;
  /** Accepted on the wire, never read. See "Orientation" in the file header. */
  servedSwap?: boolean;
  why?: string;
  voter?: string;
  dimensions?: Record<string, string>;
}

/**
 * The parsed vote. Note what is NOT here: `servedSwap`. The client's claim
 * about orientation is dropped at the parse boundary so no code downstream can
 * reach for it by accident — the only orientation in this module comes off the
 * server-written serve ticket.
 */
interface ArenaVoteInput {
  matchupId: string;
  serveId: string;
  choice: ArenaChoice;
  why: string | undefined;
  voter: string;
  dimensions: ArenaDimensionChoices | undefined;
}

/** The server's record of what it showed, and to whom. */
interface ServedOrientation {
  matchupId: string;
  servedSwap: boolean;
}

interface CompetitorReveal {
  harness: string;
  model: string;
  task: string;
  trial: number;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function isoNow(): string {
  return new Date().toISOString();
}

function requiredParsedString(value: unknown, fieldName: string): string {
  if (typeof value === "string") return value;
  throw new HttpsError("internal", `Validated callable field ${fieldName} did not parse to a string.`);
}

function optionalParsedString(value: unknown, fieldName: string): string | undefined {
  if (value === undefined || typeof value === "string") return value;
  throw new HttpsError("internal", `Validated callable field ${fieldName} did not parse to a string.`);
}

/**
 * Re-narrow the already-validated `dimensions` map to its literal types.
 *
 * `optionalEnumRecordField` has already rejected every undeclared key and
 * verdict, so this only recovers the static type the schema layer erases to
 * `Record<string, string>`; a mismatch here would be a validator bug, not bad
 * client input, hence `internal` rather than `invalid-argument`.
 */
function requiredParsedChoice(value: unknown, fieldName: string): ArenaChoice {
  const choice = requiredParsedString(value, fieldName);
  if (choice !== "A" && choice !== "B" && choice !== "tie") {
    throw new HttpsError("internal", `Validated callable field ${fieldName} did not parse to a choice.`);
  }
  return choice;
}

function optionalParsedDimensions(value: unknown, fieldName: string): ArenaDimensionChoices | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpsError("internal", `Validated callable field ${fieldName} did not parse to an object.`);
  }
  const dimensions: ArenaDimensionChoices = {};
  const entries: Record<string, unknown> = { ...value };
  for (const dimension of ARENA_DIMENSIONS) {
    const choice = entries[dimension];
    if (choice === "A" || choice === "B" || choice === "tie") dimensions[dimension] = choice;
  }
  return dimensions;
}

/**
 * Flip an "A"/"B" verdict, leaving "tie" alone.
 *
 * Applied to the overall choice and to every rubric verdict when the matchup
 * was served swapped, so a rubric row means the same thing as the overall pick
 * it sits beside — both are expressed in stored left_cell/right_cell terms.
 */
function flipChoice(choice: ArenaChoice): ArenaChoice {
  if (choice === "A") return "B";
  if (choice === "B") return "A";
  return "tie";
}

/**
 * Validate the client payload. `schemaVersion` is a version gate (only `1`
 * exists); the field bounds keep one caller from writing oversized documents.
 */
function parseArenaVoteInput(data: unknown): ArenaVoteInput {
  const parsed = parseCallableInput(
    "arenaVote",
    {
      schemaVersion: boundedInt({ min: 1, max: 1 }),
      matchupId: requiredString({ maxLength: MAX_MATCHUP_ID_CHARS }),
      serveId: requiredString({ maxLength: MAX_SERVE_ID_CHARS }),
      choice: enumField(ARENA_CHOICES, { message: "choice must be one of: A, B, tie." }),
      // Declared so a client still sending the retired field gets a working
      // vote rather than `invalid-argument` from `rejectUnknownKeys`. It is
      // parsed and then thrown away — deliberately absent from ArenaVoteInput.
      servedSwap: optionalBooleanField(),
      why: optionalString({ maxLength: MAX_WHY_CHARS }),
      voter: optionalString({ maxLength: MAX_VOTER_CHARS }),
      dimensions: optionalEnumRecordField(ARENA_DIMENSIONS, ARENA_CHOICES, {
        keyMessage: `dimensions may only contain: ${ARENA_DIMENSIONS.join(", ")}.`,
        valueMessage: "each dimensions value must be one of: A, B, tie.",
      }),
    },
    data,
    { rejectUnknownKeys: true },
  );
  return {
    matchupId: requiredParsedString(parsed.matchupId, "matchupId"),
    serveId: requiredParsedString(parsed.serveId, "serveId"),
    choice: requiredParsedChoice(parsed.choice, "choice"),
    why: optionalParsedString(parsed.why, "why"),
    voter: optionalParsedString(parsed.voter, "voter") ?? "anonymous",
    dimensions: optionalParsedDimensions(parsed.dimensions, "dimensions"),
  };
}

/**
 * Parse a cell id of the form `{harness}/{model}/{task}/trial-NN` into its
 * reveal components. Returns undefined when the stored cell id is malformed,
 * which would indicate a registry write bug rather than bad client input.
 */
function parseCellId(cellId: unknown): CompetitorReveal | undefined {
  if (typeof cellId !== "string") return undefined;
  const parts = cellId.split("/");
  if (parts.length !== 4) return undefined;
  const [harness, model, task, trialPart] = parts;
  const trial = Number(trialPart.replace(/^trial-/, ""));
  if (!harness || !model || !task || !Number.isFinite(trial)) return undefined;
  return { harness, model, task, trial };
}

/**
 * Validate a bundle entry path from the matchup registry. Only plain relative
 * paths inside the bundle directory are allowed: no leading slash, no `..`
 * segments, no URL scheme. Anything else falls back to `index.html`.
 */
function safeEntryPath(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 256) {
    return "index.html";
  }
  if (value.startsWith("/") || value.includes("..") || /^[a-z][a-z0-9+.-]*:/i.test(value)) {
    return "index.html";
  }
  return value;
}

// ---------------------------------------------------------------------------
// Serve tickets — the server's own memory of what it showed
// ---------------------------------------------------------------------------

/**
 * Persist the orientation this request is about to serve.
 *
 * This write is what makes the vote interpretable later without trusting the
 * caller. The ticket id is a v4 UUID, so it is unguessable: a caller cannot
 * mint one, and cannot enumerate other voters' tickets. The ticket names the
 * matchup it was issued for, which is what stops the substitution attack —
 * without that binding a caller could take a ticket issued for a pairing it
 * had already deanonymised and present it alongside a different matchupId,
 * borrowing the orientation it preferred.
 *
 * `served_to_uid` is null for a signed-out visitor because arenaMatchup is a
 * soft gate; the ticket is then claimable by the first uid that votes it, and
 * only that once.
 */
async function recordServedOrientation(
  firestore: Firestore,
  params: { serveId: string; matchupId: string; servedSwap: boolean; uid: string | undefined },
): Promise<void> {
  const now = Date.now();
  const expiresAtMillis = now + ARENA_SERVE_TTL_MS;
  await firestore.doc(`arena_serves/${params.serveId}`).create({
    schema_version: 1,
    serve_id: params.serveId,
    matchup_id: params.matchupId,
    served_swap: params.servedSwap,
    served_to_uid: params.uid ?? null,
    consumed_by_uid: null,
    served_at_utc: new Date(now).toISOString(),
    expires_at_millis: expiresAtMillis,
    // Timestamp form so a Firestore TTL policy on `expires_at` reaps these.
    expires_at: Timestamp.fromMillis(expiresAtMillis),
    created_at: FieldValue.serverTimestamp(),
  });
}

/**
 * Read back the orientation the server chose, refusing every route by which a
 * caller could substitute one of its own.
 *
 * Each rejection below is a specific attack, not defensive noise:
 *   - unknown ticket        -> a fabricated or already-reaped serveId;
 *   - matchup mismatch      -> this ticket's orientation belongs to a
 *                              different pairing (the substitution attack);
 *   - uid mismatch          -> a ticket issued to another signed-in voter;
 *   - already consumed      -> a replayed ticket;
 *   - expired               -> an orientation older than we are willing to
 *                              vouch for;
 *   - non-boolean swap      -> registry/ticket corruption; a vote written on a
 *                              guessed orientation is worse than no vote.
 */
async function resolveServedOrientation(
  firestore: Firestore,
  params: { serveId: string; matchupId: string; uid: string },
): Promise<ServedOrientation> {
  const snap = await firestore.doc(`arena_serves/${params.serveId}`).get();
  if (!snap.exists) {
    throw new HttpsError("failed-precondition", "This pairing is no longer live. Load a fresh pairing to vote.");
  }
  const serve = snap.data() ?? {};

  if (serve.matchup_id !== params.matchupId) {
    throw new HttpsError("permission-denied", "This ballot does not belong to that pairing.");
  }
  const servedToUid = serve.served_to_uid;
  if (typeof servedToUid === "string" && servedToUid !== params.uid) {
    throw new HttpsError("permission-denied", "This ballot was issued to a different voter.");
  }
  if (typeof serve.consumed_by_uid === "string") {
    throw new HttpsError("failed-precondition", "This ballot has already been used.");
  }
  const expiresAtMillis = typeof serve.expires_at_millis === "number" ? serve.expires_at_millis : 0;
  if (Date.now() > expiresAtMillis) {
    throw new HttpsError("failed-precondition", "This pairing has expired. Load a fresh pairing to vote.");
  }
  if (typeof serve.served_swap !== "boolean") {
    throw new HttpsError("internal", "Served orientation record is malformed.");
  }
  return { matchupId: params.matchupId, servedSwap: serve.served_swap };
}

/**
 * Burn the ticket after the vote is durable.
 *
 * Deliberately after the vote and deliberately non-fatal: the vote is the
 * durable artifact and single-use is already backstopped by the `create()`
 * dedup on `{uid}__{matchupId}`, so failing the caller's committed vote over a
 * bookkeeping write would trade a real judgment for nothing.
 */
async function consumeServeTicket(firestore: Firestore, serveId: string, uid: string): Promise<void> {
  try {
    await firestore.doc(`arena_serves/${serveId}`).update({
      consumed_by_uid: uid,
      consumed_at_utc: isoNow(),
    });
  } catch {
    // Intentionally swallowed; see the note above.
  }
}

// ---------------------------------------------------------------------------
// Bounded matchup selection
// ---------------------------------------------------------------------------

interface ServableMatchup {
  id: string;
  leftBundle: string;
  rightBundle: string;
  leftEntry: string;
  rightEntry: string;
  taskId: string;
}

function toServableMatchup(id: string, data: Record<string, unknown>): ServableMatchup | undefined {
  const leftBundle = data.left_bundle_id;
  const rightBundle = data.right_bundle_id;
  if (typeof leftBundle !== "string" || typeof rightBundle !== "string") return undefined;
  return {
    id,
    leftBundle,
    rightBundle,
    // Entry paths point the vote page's iframes at the bundle's renderable
    // file (index.html, a lone SVG, or a generated viewer). They come from our
    // own seed docs; validate the shape anyway so a bad registry write can
    // never become a traversal or absolute-URL redirect.
    leftEntry: safeEntryPath(data.left_entry),
    rightEntry: safeEntryPath(data.right_entry),
    taskId: typeof data.task_id === "string" ? data.task_id : "experiential",
  };
}

/**
 * A random point in the registry's id space.
 *
 * Matchup ids are lowercase-hex content hashes, so a random hex string of the
 * same alphabet lands uniformly across them. This is what buys a bounded read
 * without giving up the pre-registered design's ignorability (Amendment 13):
 * selection stays uniform up to id-gap variation, which for hashes is
 * negligible, instead of exactly uniform over a full-collection scan.
 */
function randomRegistryCursor(): string {
  return randomBytes(12).toString("hex");
}

async function readCandidatePage(
  firestore: Firestore,
  startAt: string | undefined,
): Promise<Array<{ id: string; data: Record<string, unknown> }>> {
  const ordered = firestore.collection("arena_matchups").orderBy(FieldPath.documentId());
  const page = startAt === undefined ? ordered : ordered.startAt(startAt);
  const snap = await page
    .select(...ARENA_MATCHUP_SERVE_FIELDS)
    .limit(ARENA_MATCHUP_PAGE_SIZE)
    .get();
  return snap.docs.map((doc) => ({ id: doc.id, data: { ...doc.data() } }));
}

/**
 * Pick one servable matchup with a read cost that does not grow with the
 * registry: a random cursor, one short forward page, and one wrap-around page
 * if that came up empty-handed.
 *
 * The already-voted exclusion is a point read on `{uid}__{matchupId}` rather
 * than the previous scan of every vote the caller has ever cast — the vote doc
 * id is deterministic, so "have they judged this one?" is a single get with no
 * index and no unbounded growth as a voter's history builds up.
 */
async function pickServableMatchup(firestore: Firestore, uid: string | undefined): Promise<ServableMatchup> {
  const seen = new Set<string>();
  let sawWellFormed = false;

  for (const cursor of [randomRegistryCursor(), undefined]) {
    for (const { id, data } of await readCandidatePage(firestore, cursor)) {
      if (seen.has(id)) continue;
      seen.add(id);
      const candidate = toServableMatchup(id, data);
      if (!candidate) continue;
      sawWellFormed = true;
      if (uid !== undefined) {
        const voted = await firestore.doc(`arena_votes/${uid}__${id}`).get();
        if (voted.exists) continue;
      }
      return candidate;
    }
  }

  if (seen.size === 0) {
    throw new HttpsError("failed-precondition", "No Arena matchups are published yet.");
  }
  if (!sawWellFormed) {
    // Entries exist but none carry artifact bundles: a registry write bug.
    throw new HttpsError("internal", "Matchup is missing artifact bundles.");
  }
  // Every candidate in reach was already judged by this voter. With a page of
  // 12 from a random cursor plus a wrap-around page, reaching this line means
  // the caller has judged essentially the whole registry.
  throw new HttpsError("failed-precondition", "You've judged every pairing we can offer right now.");
}

// ---------------------------------------------------------------------------
// Callable
// ---------------------------------------------------------------------------

export const arenaVote = onCallProduction<ArenaVoteRequest, Record<string, unknown>>(
  "arenaVote",
  {
    region: FUNCTIONS_REGION,
    // Lower than authenticated callables: this surface is open to the internet.
    maxInstances: 25,
    timeoutSeconds: 30,
  },
  async (request) => {
    // Require Firebase Auth: one person, one vote per matchup.
    assertAuth(request);
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Request must be authenticated with Firebase Auth.");
    }

    const input = parseArenaVoteInput(request.data);

    // Reject ids that would collide with the dedup-doc-id scheme
    // (`{uid}__{matchupId}`) or escape their collection. A `/` would create a
    // subcollection path; we only ever publish ids without slashes, but
    // validate defensively.
    if (input.matchupId.includes("/")) {
      throw new HttpsError("invalid-argument", "matchupId must not contain '/'.");
    }
    if (input.serveId.includes("/")) {
      throw new HttpsError("invalid-argument", "serveId must not contain '/'.");
    }

    // Bound abuse per VOTER after validation but before any write. Keyed on
    // uid: an IP-keyed bound here would be either free to bypass with a header
    // or shared by the entire internet, and ballot stuffing is an identity
    // problem, not an address problem.
    await checkArenaVoteRateLimit(uid, request.rawRequest);

    const firestore = getFirestore();

    // Recover the orientation this caller was actually shown. This must happen
    // before anything is written: a vote whose choice→cell mapping cannot be
    // established server-side is not a vote we can honestly count.
    const served = await resolveServedOrientation(firestore, {
      serveId: input.serveId,
      matchupId: input.matchupId,
      uid,
    });

    // Resolve the matchup registry entry (server-side identities). A vote for
    // an unknown matchup is rejected: the Arena only counts votes against
    // matchups it actually served.
    const matchupRef = firestore.doc(`arena_matchups/${input.matchupId}`);
    const matchupSnap = await matchupRef.get();
    if (!matchupSnap.exists) {
      throw new HttpsError("not-found", "Unknown matchupId.");
    }
    const matchup = matchupSnap.data() ?? {};
    const storedLeft = parseCellId(matchup.left_cell);
    const storedRight = parseCellId(matchup.right_cell);
    if (!storedLeft || !storedRight) {
      // Registry corruption is a server fault, not a client fault.
      throw new HttpsError("internal", "Matchup registry entry is malformed.");
    }

    // Normalize the choice to the stored orientation, using the SERVER's record
    // of what was displayed. The voter picked a side of the screen; when the
    // matchup was served swapped, the displayed "A"/"B" map to the stored
    // right/left respectively, so flip the choice to keep left_cell/right_cell
    // semantics consistent for the ratings pipeline. Every rubric verdict is
    // flipped the same way and for the same reason: they are judgments of the
    // same two artifacts, so they must land in the same orientation as the
    // overall pick or a swapped matchup would file a dimension win against the
    // wrong competitor.
    let choice = input.choice;
    let dimensions = input.dimensions;
    if (served.servedSwap) {
      choice = flipChoice(choice);
      if (dimensions) {
        const flipped: ArenaDimensionChoices = {};
        for (const dimension of ARENA_DIMENSIONS) {
          const verdict = dimensions[dimension];
          if (verdict !== undefined) flipped[dimension] = flipChoice(verdict);
        }
        dimensions = flipped;
      }
    }

    // Write the vote (append-only) BEFORE revealing identities. The vote doc
    // carries the matchup fields denormalized so the offline sync
    // (runner/arena_sync.py) can mirror it without a second lookup. The vote
    // id is a server-generated UUID used as both the vote_id field and the
    // document id's suffix (the doc id is `{uid}__{matchupId}` for one-vote-
    // per-user-per-matchup dedup). `create()` fails atomically if a vote
    // already exists for this pairing — race-proof without a transaction.
    const voteId = randomUUID();
    const voteDocId = `${uid}__${input.matchupId}`;
    const voteRef = firestore.collection("arena_votes").doc(voteDocId);
    try {
      await voteRef.create({
        vote_id: voteId,
        matchup_id: input.matchupId,
        voter_uid: uid,
        task_id: matchup.task_id ?? null,
        left_cell: matchup.left_cell ?? null,
        right_cell: matchup.right_cell ?? null,
        order: matchup.order ?? null,
        choice,
        // Sparse rubric in stored orientation, or null when the voter skipped
        // it — which is the shape every pre-rubric vote effectively has.
        dimensions: dimensions ?? null,
        // Server-recorded orientation, plus the ticket it came from, so an
        // audit of the ratings can retrace any ballot's choice→cell mapping
        // without taking the client's word for it.
        served_swap: served.servedSwap,
        serve_id: input.serveId,
        why: input.why ?? null,
        voter: input.voter,
        created_at_utc: isoNow(),
        created_at: FieldValue.serverTimestamp(),
      });
    } catch (err) {
      // Firestore create() on an existing doc throws ALREADY_EXISTS.
      if (err instanceof Error && err.message.includes("ALREADY_EXISTS")) {
        throw new HttpsError("already-exists", "You already judged this pairing.");
      }
      throw err;
    }

    // Single-use: burn the ticket now that the judgment is durable.
    await consumeServeTicket(firestore, input.serveId, uid);

    // Reveal only after the write has committed, and in the orientation the
    // voter actually SAW — `reveal.left` is the artifact that was on their
    // left, not `left_cell`. Returning stored orientation here mislabelled the
    // two identity cards on exactly the half of matchups that were served
    // swapped, which is both a correctness bug and, less obviously, a leak:
    // a client that could tell the two apart could infer `servedSwap`, which
    // the server otherwise never discloses.
    const reveal = served.servedSwap
      ? { left: storedRight, right: storedLeft }
      : { left: storedLeft, right: storedRight };
    return {
      voteId,
      reveal,
      ranAt: isoNow(),
    };
  },
);

// ---------------------------------------------------------------------------
// Matchup serving
// ---------------------------------------------------------------------------

/**
 * Public BurnBench Arena matchup callable.
 *
 * Serves one blind pairwise matchup to a voter: two anonymized, content-hashed
 * artifact bundle ids (left/right) with position randomized server-side per
 * request, and the matchupId the voter echoes back to `arenaVote`. Competitor
 * identities are NEVER sent here — they are revealed only by `arenaVote` after
 * the vote commits.
 *
 * Wire contract (request):  data: { schemaVersion: 1 }
 * Wire contract (response):
 *   {
 *     matchupId: string,
 *     serveId: string,              // opaque single-use ballot, echo to arenaVote
 *     task: string,                 // task family label for framing, not identity
 *     left:  { bundleId, entry },   // anonymized artifact bundle (content hash)
 *     right: { bundleId, entry },
 *     ranAt: ISO8601 string,
 *   }
 *
 * NOTE what this response no longer contains: `servedSwap`. The orientation is
 * recorded server-side against `serveId` and never disclosed. Publishing it
 * was the multiplier that made a harvested identity map dangerous — knowing
 * "pairing M is X vs Y" is inert, but knowing "and today you are seeing Y on
 * the left" is a fully-informed strategic vote against a blind benchmark. The
 * client does not need it: it renders `left` and `right` exactly as served.
 *
 * Selection is random over the published matchup registry, matching the
 * pre-registered balanced stratified-uniform design (Amendment 13): the
 * registry is already balanced across pairs and tasks, so uniform selection
 * over it preserves the ignorability the ratings model relies on. It is drawn
 * with a bounded read (see `pickServableMatchup`), which is uniform up to
 * id-gap variation over hash-shaped ids rather than exactly uniform — a
 * deliberate trade against reading all ~13.8k registry entries per request.
 * Per-request position randomization keeps left/right assignment decoupled
 * from identity. When the caller is signed in, matchups they have already
 * voted on are excluded so they never see the same pairing twice.
 *
 * Auth contract: optional auth. No App Check. Rate-limited before any read,
 * keyed on uid when signed in (see `checkArenaMatchupRateLimit`).
 */
export const arenaMatchup = onCallProduction<Record<string, unknown>, Record<string, unknown>>(
  "arenaMatchup",
  {
    region: FUNCTIONS_REGION,
    maxInstances: 25,
    timeoutSeconds: 30,
  },
  async (request) => {
    parseCallableInput("arenaMatchup", { schemaVersion: boundedInt({ min: 1, max: 1 }) }, request.data);

    // Optional auth: key the limit on the uid when we have one, because that is
    // the only identity a caller cannot mint for free.
    const uid = request.auth?.uid;
    await checkArenaMatchupRateLimit({ uid, req: request.rawRequest });

    const firestore = getFirestore();
    const picked = await pickServableMatchup(firestore, uid);

    // Position is randomized per request so the served left/right is decoupled
    // from the stored order. Drawn from the CSPRNG, not `Math.random()`: this
    // coin flip is now the hidden variable that keeps a caller from knowing
    // which stored cell it is looking at, and a predictable PRNG would hand
    // that back. The result is written down server-side and returned only as
    // an opaque ticket — the client is told the layout, never the mapping.
    const servedSwap = randomInt(2) === 1;
    const serveId = randomUUID();
    await recordServedOrientation(firestore, { serveId, matchupId: picked.id, servedSwap, uid });

    return {
      matchupId: picked.id,
      serveId,
      task: picked.taskId,
      left: {
        bundleId: servedSwap ? picked.rightBundle : picked.leftBundle,
        entry: servedSwap ? picked.rightEntry : picked.leftEntry,
      },
      right: {
        bundleId: servedSwap ? picked.leftBundle : picked.rightBundle,
        entry: servedSwap ? picked.leftEntry : picked.rightEntry,
      },
      ranAt: isoNow(),
    };
  },
);
