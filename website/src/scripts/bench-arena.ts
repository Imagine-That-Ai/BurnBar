/**
 * @fileoverview BurnBench Arena voting client module.
 *
 * Drives /bench/arena/vote: fetch one blind pairwise matchup from the
 * `arenaMatchup` callable, render the two anonymized artifact bundles side by
 * side in sandboxed iframes, take the voter's choice, submit it to `arenaVote`,
 * then reveal which harness × model built which artifact.
 *
 * Blind-until-reveal is enforced end to end:
 *  - The matchup response carries only content-hash bundle ids + a matchupId;
 *    competitor identities are never sent to the client before a vote.
 *  - Artifacts render in cross-origin sandboxed iframes (the arena-artifacts
 *    site serves a CSP that disables network access), so an artifact cannot
 *    phone home its identity or position.
 *  - Identities appear only in the `arenaVote` response, after the vote write
 *    has committed server-side.
 *
 * Orientation is server-authoritative, and this client is deliberately blind to
 * it. `arenaMatchup` flips a CSPRNG coin, records the result against an opaque
 * single-use ticket (`serveId`), and serves `left`/`right` ALREADY in the
 * orientation the voter is meant to see. The flip itself is never sent here.
 * The client's whole job is to render what it was served and hand the ticket
 * back: `arenaVote` reads the orientation off the ticket, so the choice→cell
 * mapping is reconstructed server-side without trusting anything we say.
 *
 * This replaced an echo design in which the server sent `servedSwap` and the
 * client sent it back. That field is gone from both directions: a caller that
 * could assert its own orientation could invert the meaning of every ballot it
 * cast, and the published Bradley-Terry ratings would faithfully record the
 * inversion. `serveId` is now REQUIRED on a vote; omitting it is
 * `invalid-argument`.
 *
 * The reveal returned by `arenaVote` is in that same SERVED orientation —
 * `reveal.left` is the artifact that was physically on the voter's left. So
 * every left/right → A/B mapping in this file is the identity map, funnelled
 * through {@link servedSides} so no single call site can drift into
 * re-swapping and mislabel the reveal on the half of matchups the server chose
 * to swap.
 */

import { getApp, getApps, initializeApp } from "firebase/app";
import { getFunctions, httpsCallable } from "firebase/functions";
import {
  FacebookAuthProvider,
  getAuth,
  GithubAuthProvider,
  GoogleAuthProvider,
  OAuthProvider,
  signInWithPopup,
  signInWithRedirect,
  getRedirectResult,
  onAuthStateChanged,
  signOut,
  type AuthProvider,
  type User
} from "firebase/auth";
import { firebaseConfig } from "../lib/firebaseClient";
import {
  EVENT,
  trackEmailCapturedIfNewAccount,
  trackEvent,
  type ArenaSignInProvider
} from "../lib/analytics";
import { arenaTaskBrief } from "./arena-tasks";
import { buildIdentityCard } from "./arena-identities";
import { at, closestFrom, query, targetAs } from "./dom.js";
import { initArenaNet } from "./arena-net";

/* The artifacts hosting origin (separate Firebase Hosting site, locked CSP).
 * In dev (localhost/127.0.0.1) the prod artifacts site's frame-ancestors CSP
 * blocks embedding from non-prod origins, so we auto-fallback to a local
 * static server on port 5506 (run `node scripts/serve-arena.mjs`). Override
 * with ?artifacts=http://127.0.0.1:<port>. */
const ARTIFACTS_ORIGIN_PROD = "https://burnbar-arena-artifacts.web.app";
const ARTIFACTS_ORIGIN_DEV = "http://127.0.0.1:5506";

/* Visual A/B/C variant, assigned pre-paint by the inline bootstrap in
 * vote.astro (?v= override, else sticky localStorage bucket). Read-only here;
 * "unknown" covers stale markup or a blocked bootstrap. */
const ARENA_VARIANT = document.documentElement.dataset.arenaVariant ?? "unknown";

/** Report the variant exposure once per session per variant, and boot any
 *  variant-only dressing (the neural particle field). */
function initVariantExperiment(): void {
  try {
    const key = `bb_arena_exp:${ARENA_VARIANT}`;
    if (!sessionStorage.getItem(key)) {
      sessionStorage.setItem(key, "1");
      trackEvent(EVENT.arenaVariantExposed, { variant: ARENA_VARIANT });
    }
  } catch {
    // Storage blocked: still report the exposure; dedupe is best-effort.
    trackEvent(EVENT.arenaVariantExposed, { variant: ARENA_VARIANT });
  }
  if (ARENA_VARIANT === "neural") {
    const canvas = document.getElementById("arena-net");
    if (canvas instanceof HTMLCanvasElement) initArenaNet(canvas);
  }
}

/*
 * Dev affordance: the artifacts site's CSP frame-ancestors lists only the
 * production origins, so a page served from loopback cannot embed them. When
 * iterating on this page locally (e.g. the hosting emulator), pass
 * ?artifacts=http://127.0.0.1:<port> pointing at a locally emulated artifacts
 * site. Inert on any non-loopback host, and the page's own CSP frame-src
 * still constrains which origins may be framed.
 */
const devArtifactsOrigin = (() => {
  if (!/^(localhost|127\.0\.0\.1)$/.test(location.hostname)) return null;
  const candidate = new URLSearchParams(location.search).get("artifacts");
  if (candidate && /^https?:\/\/[\w.:@-]+$/.test(candidate)) return candidate;
  // Auto-fallback: the local static artifacts server (scripts/serve-arena.mjs).
  // If it isn't running, the iframes simply fail to load — same as the prod
  // frame-ancestors block, but without the CSP console noise.
  return ARTIFACTS_ORIGIN_DEV;
})();

const ARTIFACTS_ORIGIN = devArtifactsOrigin ?? ARTIFACTS_ORIGIN_PROD;

/*
 * The Arena callables are public: no Auth, no App Check enforcement, abuse
 * bounded by server-side per-IP rate limits. Use a dedicated app instance
 * WITHOUT App Check here. The shared client initializes reCAPTCHA Enterprise
 * App Check, and the Functions SDK awaits an App Check token before firing a
 * callable — a hung or blocked reCAPTCHA (privacy browsers, automation,
 * network filters) would otherwise stall "Dealing a blind matchup…" forever
 * even though the server never required the token.
 */
/*
 * Serve the auth handler from the page's own origin.
 *
 * Firebase's popup flow makes two identitytoolkit calls that the web API key's
 * HTTP-referrer allowlist can reject, and both failures look identical to a
 * voter — the window opens and vanishes before they can do anything:
 *
 *   1. signInWithPopup opens a blank popup, then _validateOrigin() calls
 *      GET identitytoolkit/v1/projects with Referer: <this page's origin>.
 *      A 403 rejects with a code synthesized from the server message
 *      (auth/requests-from-referer-<origin>-are-blocked.) and Firebase closes
 *      the popup it just opened.
 *   2. The popup loads https://<authDomain>/__/auth/handler, which repeats that
 *      call with Referer: <authDomain>. A 403 there logs "Unable to verify that
 *      the app domain is authorized", renders "The requested action is
 *      invalid.", and the popup closes itself.
 *
 * burnbar.firebaseapp.com is NOT on the key's referrer allowlist, so every host
 * that falls back to it dies at step 2 — that previously included
 * www.burnbar.ai and app.burnbar.ai, which are on the allowlist themselves and
 * serve /__/auth/handler from their own origin. Keep the handler same-origin
 * for those hosts. Same-origin also keeps Safari ITP happy: the popup's
 * sessionStorage stays first-party rather than third-party on firebaseapp.com.
 *
 * Hosts outside this set (localhost, preview channels) keep the firebaseapp.com
 * default because they do not serve /__/auth/handler themselves. Sign-in there
 * needs the origin added to the API key's referrer allowlist.
 */
const SAME_ORIGIN_AUTH_DOMAINS = new Set(["burnbar.ai", "www.burnbar.ai", "app.burnbar.ai"]);
const arenaFirebaseConfig = { ...firebaseConfig };
if (typeof window !== "undefined" && SAME_ORIGIN_AUTH_DOMAINS.has(location.hostname)) {
  arenaFirebaseConfig.authDomain = location.hostname;
}
const arenaApp = getApps().some((a) => a.name === "arena-public")
  ? getApp("arena-public")
  : initializeApp(arenaFirebaseConfig, "arena-public");
const arenaFunctions = getFunctions(arenaApp, "us-central1");

/* ---------- auth: sign in to vote (soft gate) ----------
 * The arena uses its own Auth instance on the arena-public app (the App
 * Check-free instance used by the callables). This gives the arena a
 * self-contained session: the main site's sign-in state is separate, so a
 * visitor can browse the site logged out and judge arena pairings logged in
 * (or vice-versa) without one leaking into the other. The ID token from this
 * Auth instance is automatically attached to arenaVote/arenaMatchup calls
 * by the Functions SDK.
 */
const arenaAuth = getAuth(arenaApp);
const arenaGoogleProvider = new GoogleAuthProvider();
const arenaAppleProvider = new OAuthProvider("apple.com");
arenaAppleProvider.addScope("email");
arenaAppleProvider.addScope("name");
const arenaGithubProvider = new GithubAuthProvider();
arenaGithubProvider.addScope("read:user");
arenaGithubProvider.addScope("user:email");
const arenaFacebookProvider = new FacebookAuthProvider();
arenaFacebookProvider.addScope("email");
const arenaProviders: Record<ArenaSignInProvider, AuthProvider> = {
  google: arenaGoogleProvider,
  apple: arenaAppleProvider,
  github: arenaGithubProvider,
  facebook: arenaFacebookProvider
};
const arenaProviderLabels: Record<ArenaSignInProvider, string> = {
  google: "Google",
  apple: "Apple",
  github: "GitHub",
  facebook: "Meta"
};

/** The currently signed-in user, or null when anonymous. */
let arenaUser: User | null = null;
/** A vote the voter tried to cast while signed out; auto-submitted on sign-in. */
let pendingVote: Choice | null = null;
/** The rubric that accompanied `pendingVote`, kept so a redirect can't eat it. */
let pendingRubric: RubricChoices | undefined;
const PENDING_VOTE_KEY = "bb_arena_pending_vote";
const PENDING_RUBRIC_KEY = "bb_arena_pending_rubric";
const REDIRECT_PROVIDER_KEY = "bb_arena_redirect_provider";

/** Bound every callable wait so a stalled network surfaces as an error state. */
const CALLABLE_TIMEOUT_MS = 20_000;

/**
 * A local stand-in for a callable rejection, shaped like the real thing.
 *
 * The Firebase SDK reports the reason on `error.code` (see
 * {@link callableErrorCode}), so a client-side timeout has to carry a `code`
 * too or it would fall through every branch that classifies a failure.
 */
class CallableTimeoutError extends Error {
  readonly code = "functions/deadline-exceeded";
  constructor() {
    super("The request took too long. Check your connection and try again.");
    this.name = "CallableTimeoutError";
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_resolve, reject) => {
      setTimeout(() => reject(new CallableTimeoutError()), ms);
    })
  ]);
}

interface MatchupResponse {
  matchupId: string;
  /**
   * Opaque single-use ballot minted by `arenaMatchup`, echoed to `arenaVote`.
   *
   * This is the ONLY handle the client has on the orientation it was served;
   * the orientation itself stays on the server, keyed by this id. A vote
   * without it is rejected with `invalid-argument`.
   */
  serveId: string;
  task: string;
  left: { bundleId: string; entry: string };
  right: { bundleId: string; entry: string };
}

interface CompetitorReveal {
  harness: string;
  model: string;
  task: string;
  trial: number;
}

interface VoteResponse {
  voteId: string;
  reveal: { left: CompetitorReveal; right: CompetitorReveal };
}

type Choice = "A" | "B" | "tie";

/**
 * Closed rubric vocabulary, mirrored from the server contract.
 *
 * Adding an axis is a coordinated change across three places: this list, the
 * `ARENA_DIMENSIONS` constant in `functions/src/arenaVote.ts` (which rejects
 * anything undeclared, fail-closed), and `runner/arena_schema.py` in the bench
 * repo. The `<fieldset data-dimension>` rows in vote.astro carry these exact
 * keys; a row whose key is not listed here is skipped rather than sent, so a
 * markup typo degrades to "no rubric row" instead of a rejected vote.
 */
const ARENA_DIMENSIONS = [
  "visual_polish",
  "interaction_quality",
  "accessibility",
  "code_quality"
] as const;
type ArenaDimension = (typeof ARENA_DIMENSIONS)[number];
type RubricChoices = Partial<Record<ArenaDimension, Choice>>;

const DIMENSION_SET = new Set<string>(ARENA_DIMENSIONS);

function isDimension(value: string): value is ArenaDimension {
  return DIMENSION_SET.has(value);
}

function isChoice(value: string): value is Choice {
  return value === "A" || value === "B" || value === "tie";
}

/* ---------- orientation: one identity map, four call sites ---------- */

/**
 * Map a server-served `left`/`right` pair onto the ballot's A and B slots.
 *
 * It is the identity map, and that is the entire point. Both server responses
 * are already expressed in the orientation the voter sees:
 *   - `arenaMatchup` applies its coin flip BEFORE serving, so `left` is the
 *     bundle to put in the left-hand frame, full stop;
 *   - `arenaVote`'s `reveal` comes back in that same served orientation, so
 *     `reveal.left` is the identity of the artifact that was on the left.
 * There is therefore no orientation work left for this client to do, and the
 * only way to be wrong is to invent some.
 *
 * That is exactly the bug this function exists to make unwritable. Before the
 * serve-ticket redesign the reveal came back in STORED orientation while the
 * frames were in served orientation, so "Artifact A" on the reveal card named
 * the wrong stack on every swapped matchup — half of them. Re-introducing a
 * flip on any one of the four paths below (preview frames, restart, stage
 * frames, reveal cards) would double-swap and bring that back for precisely
 * the matchups a reader is least able to check. One shared identity map means
 * the four paths cannot disagree.
 *
 * @param pair Any left/right pair served by the Arena callables.
 * @returns The same two values keyed by the slot that displays them.
 */
export function servedSides<T>(pair: { left: T; right: T }): { a: T; b: T } {
  return { a: pair.left, b: pair.right };
}

/* ---------- callable failures: read the code, never the prose ---------- */

/**
 * The gRPC-style reason a callable rejected, with the SDK's namespace stripped.
 *
 * The Firebase JS SDK puts the machine-readable reason on `error.code`,
 * prefixed with its product namespace (`functions/failed-precondition`), and
 * leaves `error.message` as the server's human sentence ("This pairing has
 * expired. Load a fresh pairing to vote."). Sniffing the message for a code —
 * which this file used to do in two places — therefore never matched anything:
 * a duplicate vote, an expired ballot and a genuine server fault all fell
 * through to the same generic dead end, and the recovery paths written for
 * them were unreachable code.
 *
 * @returns The bare code (e.g. `"already-exists"`), or `""` when the rejection
 *   is not a coded callable error at all.
 */
export function callableErrorCode(err: unknown): string {
  if (typeof err !== "object" || err === null || !("code" in err)) return "";
  const code: unknown = Reflect.get(err, "code");
  return typeof code === "string" ? code.replace(/^functions\//, "") : "";
}

/**
 * Codes that mean "this specific ballot is spent; the fix is a new pairing".
 *
 * All four are dead ends for the CURRENT matchup and none of them are the
 * voter's fault, so the recovery is identical: silently deal a fresh pairing
 * instead of parking them on an error they cannot act on.
 *   - `failed-precondition` — the serve ticket is unknown, expired or already
 *     used (the tab sat open overnight, or the vote was retried);
 *   - `permission-denied`   — the ticket does not belong to this pairing or
 *     was issued to a different voter;
 *   - `already-exists`      — this voter already judged this pairing, so the
 *     one-vote-per-matchup `create()` refused it;
 *   - `not-found`           — the matchup left the registry between serve and
 *     vote.
 * Re-fetching cannot loop: {@link loadMatchup} reports its own failures and
 * never re-enters the vote path.
 */
const STALE_BALLOT_CODES = new Set([
  "failed-precondition",
  "permission-denied",
  "already-exists",
  "not-found"
]);

/** True when the only sensible recovery is a fresh pairing. */
export function isStaleBallot(err: unknown): boolean {
  return STALE_BALLOT_CODES.has(callableErrorCode(err));
}

/**
 * What to tell a voter whose ballot went stale, given the code.
 *
 * Each line names the actual cause and then says what is about to happen, so
 * the pairing swapping out from under them reads as the system working rather
 * than as their vote vanishing. The vote genuinely was not counted in every
 * one of these cases except `already-exists`, where their earlier vote stands.
 */
function staleBallotMessage(code: string): string {
  if (code === "already-exists") return "Already judged this pairing — dealing a fresh one.";
  if (code === "permission-denied")
    return "That ballot didn't match the pairing — dealing a fresh one.";
  if (code === "not-found") return "That pairing is no longer published — dealing a fresh one.";
  return "That ballot expired before it landed — dealing a fresh one.";
}

/**
 * What the vote path should DO about a rejection.
 *
 * A decision, not a side effect, so the policy is testable without a DOM, a
 * signed-in user or a network — and so the three outcomes stay exhaustive:
 *   - `refetch` — the ballot is spent; say so and deal a fresh pairing rather
 *     than leaving the voter staring at a pairing they can no longer vote on;
 *   - `reauth`  — the session lapsed; re-open the sign-in gate, keeping the
 *     choice and rubric pending so the vote lands the moment they return;
 *   - `status`  — nothing to do but say what happened.
 */
export type VoteFailureAction =
  | { kind: "refetch"; status: string }
  | { kind: "reauth" }
  | { kind: "status"; status: string };

export function voteFailureAction(err: unknown): VoteFailureAction {
  const code = callableErrorCode(err);
  if (isStaleBallot(err)) return { kind: "refetch", status: staleBallotMessage(code) };
  if (code === "unauthenticated") return { kind: "reauth" };
  if (code === "resource-exhausted") {
    return {
      kind: "status",
      status: "You've hit the vote rate limit. Thanks for the enthusiasm — try again later."
    };
  }
  if (code === "deadline-exceeded") {
    return {
      kind: "status",
      status: "Recording your vote timed out. Nothing was counted; please retry."
    };
  }
  return {
    kind: "status",
    status: "Your vote could not be recorded. Nothing was counted; please retry."
  };
}

const arenaMatchup = httpsCallable<Record<string, unknown>, MatchupResponse>(
  arenaFunctions,
  "arenaMatchup"
);
const arenaVote = httpsCallable<Record<string, unknown>, VoteResponse>(arenaFunctions, "arenaVote");

function el<T extends HTMLElement>(id: string, ctor: abstract new () => T): T | null {
  const node = document.getElementById(id);
  return node instanceof ctor ? node : null;
}

function setStatus(message: string): void {
  const node = el("arena-status", HTMLElement);
  if (node) node.textContent = message;
}

/** Show the task brief for the dealt matchup (same brief both sides ran),
 *  on the ballot card and inside the full-screen stage. */
function renderBrief(taskId: string): void {
  const brief = arenaTaskBrief(taskId);
  const card = el("arena-brief", HTMLElement);
  const title = el("brief-title", HTMLElement);
  const text = el("brief-text", HTMLElement);
  const judge = el("brief-judge", HTMLElement);
  if (title) title.textContent = brief.title;
  if (text) text.textContent = brief.brief;
  if (judge) judge.textContent = brief.judgeOn.join(" · ");
  if (card) card.hidden = false;
  const stageTitle = el("stage-brief-title", HTMLElement);
  const stageText = el("stage-brief-text", HTMLElement);
  const stageJudge = el("stage-brief-judge", HTMLElement);
  if (stageTitle) stageTitle.textContent = brief.title;
  if (stageText) stageText.textContent = ` — ${brief.brief}`;
  if (stageJudge) stageJudge.textContent = brief.judgeOn.join(" · ");
}

function bundleUrl(bundleId: string, entry: string): string {
  // entry is the bundle's renderable file (index.html, a lone SVG, or a
  // generated viewer), validated server-side as a plain relative path.
  const safeEntry = /^[\w./-]+$/.test(entry) && !entry.includes("..") ? entry : "index.html";
  return `${ARTIFACTS_ORIGIN}/bundles/${encodeURIComponent(bundleId)}/${safeEntry}`;
}

/** Current matchup state, held between serve and vote. */
let current: MatchupResponse | null = null;
let voting = false;
/** The choice that was just recorded, for the "your pick" reveal marker. */
let lastChoice: Choice | null = null;

/* ---------- stage: full-screen carousel inspector ---------- */

type StageSide = "a" | "b";

let stageOpen = false;
let stageSide: StageSide = "a";
/** Each stage frame loads lazily, once per matchup. */
const stageLoaded: Record<StageSide, boolean> = { a: false, b: false };

function stageFrame(side: StageSide): HTMLIFrameElement | null {
  return el(side === "a" ? "stage-frame-a" : "stage-frame-b", HTMLIFrameElement);
}

function stageTab(side: StageSide): HTMLButtonElement | null {
  return el(side === "a" ? "stage-tab-a" : "stage-tab-b", HTMLButtonElement);
}

function showStageSide(side: StageSide): void {
  stageSide = side;
  const other: StageSide = side === "a" ? "b" : "a";
  el(`stage-zoomwrap-${side}`, HTMLElement)?.removeAttribute("hidden");
  el(`stage-zoomwrap-${other}`, HTMLElement)?.setAttribute("hidden", "");
  el(`stage-zoombar-${side}`, HTMLElement)?.removeAttribute("hidden");
  el(`stage-zoombar-${other}`, HTMLElement)?.setAttribute("hidden", "");
  stageTab(side)?.setAttribute("aria-selected", "true");
  stageTab(other)?.setAttribute("aria-selected", "false");
}

function stageDialog(): HTMLDialogElement | null {
  return el("arena-stage", HTMLDialogElement);
}

function openStage(side: StageSide): void {
  if (!current) return;
  const dialog = stageDialog();
  if (!dialog || dialog.open) return;
  markPlayed(side);
  // Same URLs as the preview frames, so the browser cache carries the load;
  // both frames stay mounted so each artifact's live state (a game mid-run,
  // a tweaked control) survives flipping between A and B.
  const bundles = servedSides(current);
  if (!stageLoaded.a) {
    const frame = stageFrame("a");
    if (frame) frame.src = bundleUrl(bundles.a.bundleId, bundles.a.entry);
    stageLoaded.a = true;
  }
  if (!stageLoaded.b) {
    const frame = stageFrame("b");
    if (frame) frame.src = bundleUrl(bundles.b.bundleId, bundles.b.entry);
    stageLoaded.b = true;
  }
  showStageSide(side);
  // showModal() puts the dialog in the top layer: above the sticky site
  // header and any stacking context the page content lives in, with native
  // Esc handling and focus containment.
  dialog.showModal();
  stageOpen = true;
  document.body.style.overflow = "hidden";
  el("stage-close", HTMLButtonElement)?.focus();
}

function closeStage(): void {
  const dialog = stageDialog();
  if (dialog?.open) dialog.close();
}

/** Reset the stage for a new matchup (or teardown): unload frames, restore labels. */
function resetStage(): void {
  closeStage();
  stageLoaded.a = false;
  stageLoaded.b = false;
  for (const side of ["a", "b"] as const) {
    stageFrame(side)?.removeAttribute("src");
    const tab = stageTab(side);
    if (tab) tab.textContent = side === "a" ? "Artifact A" : "Artifact B";
  }
}

/* ---------- live artifacts: the thing is playable in place ----------
 *
 * Judging "did it ship" needs hands on the artifact, not a screenshot: half
 * of these tasks are games and dashboards whose quality only shows up under
 * input. So each preview frame is a real, usable app inside the ballot.
 *
 * The shield is the one piece of ceremony: until the voter opts in, the frame
 * is inert and untabbable, so scrolling past the ballot can never be
 * swallowed by a live canvas and a stray tab never lands inside an artifact.
 * One press hands over pointer and keyboard; the stage (⤢) stays available
 * for a bigger canvas, and restart (↺) re-runs a game or clears a form
 * without disturbing the matchup.
 */

type Side = "a" | "b";

/** Sides the voter actually used this matchup — the played signal fires once
 *  per side per matchup, whether they engaged in place or on the stage. */
const played: Record<Side, boolean> = { a: false, b: false };

function frameFor(side: Side): HTMLIFrameElement | null {
  return el(`frame-${side}`, HTMLIFrameElement);
}

function wrapFor(side: Side): HTMLElement | null {
  return el(`wrap-${side}`, HTMLElement);
}

function markPlayed(side: Side): void {
  if (played[side]) return;
  played[side] = true;
  trackEvent(EVENT.arenaArtifactPlayed, {
    variant: ARENA_VARIANT,
    side: side === "a" ? "A" : "B"
  });
}

/** Hand pointer + keyboard to the artifact, in place. */
function activateFrame(side: Side, focusFrame = true): void {
  const wrap = wrapFor(side);
  const frame = frameFor(side);
  if (!wrap || !frame) return;
  markPlayed(side);
  if (wrap.dataset.live === "true") return;
  wrap.dataset.live = "true";
  frame.removeAttribute("tabindex");
  const badge = el(`live-${side}`, HTMLElement);
  // Written (not just revealed) so role="status" actually announces it.
  if (badge) badge.textContent = `live · ${side.toUpperCase()} responds to you`;
  // Focus the frame so a keyboard-driven artifact (every game here) responds
  // to the very next keystroke instead of demanding a second click inside.
  if (focusFrame) frame.focus({ preventScroll: true });
}

/** Re-arm the shield: used between matchups so a fresh pair starts inert. */
function deactivateFrame(side: Side): void {
  const wrap = wrapFor(side);
  const frame = frameFor(side);
  if (wrap) wrap.dataset.live = "false";
  frame?.setAttribute("tabindex", "-1");
  const badge = el(`live-${side}`, HTMLElement);
  if (badge) badge.textContent = "";
}

/** Re-run the artifact from a clean slate, keeping it live and focused. */
function reloadFrame(side: Side): void {
  const frame = frameFor(side);
  if (!frame || !current) return;
  const cell = servedSides(current)[side];
  frame.src = bundleUrl(cell.bundleId, cell.entry);
  activateFrame(side, false);
}

/* ---------- zoom: pinch/wheel/drag/keys, inline + stage ----------
 * One tiny controller per artifact surface. The artifact itself (the iframe)
 * is never transformed for layout — only the inner .bb-*zoomer is scaled and
 * panned. Buttons, wheel+meta/ctrl, pinch, drag-when-zoomed, double-click
 * reset, and +/-/0 keys all funnel through the same clamp. Pan stays bounded
 * so the scaled artifact cannot be dragged entirely out of its clipped wrap.
 */

type ZoomTarget = "inline" | "stage";
interface ZoomState {
  scale: number;
  x: number;
  y: number;
}
const ZOOM_MIN = 0.4;
const ZOOM_MAX = 3.0;
const ZOOM_STEP = 0.1;
const ZOOM_PAN_THRESHOLD = 1.01;
const zoomState: Record<string, ZoomState> = {};

function zoomKey(side: Side, target: ZoomTarget): string {
  return `${target}:${side}`;
}
function zoomWrapEl(side: Side, target: ZoomTarget): HTMLElement | null {
  return target === "stage"
    ? el(`stage-zoomwrap-${side}`, HTMLElement)
    : el(`zoomwrap-${side}`, HTMLElement);
}
function zoomerEl(side: Side, target: ZoomTarget): HTMLElement | null {
  return target === "stage"
    ? el(`stage-zoomer-${side}`, HTMLElement)
    : el(`zoomer-${side}`, HTMLElement);
}
function clampZoom(v: number): number {
  return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, v));
}
function clampPan(px: number, py: number, wrap: HTMLElement, scale: number): [number, number] {
  if (scale <= ZOOM_PAN_THRESHOLD) return [0, 0];
  const w = wrap.clientWidth;
  const h = wrap.clientHeight;
  // The transform is centered at 1×. These are the exact distances needed
  // to bring either edge of the scaled viewport back to the wrap's edge.
  const maxX = Math.max(0, (w * scale - w) / 2);
  const maxY = Math.max(0, (h * scale - h) / 2);
  return [Math.max(-maxX, Math.min(maxX, px)), Math.max(-maxY, Math.min(maxY, py))];
}
function applyZoom(side: Side, target: ZoomTarget): void {
  const wrap = zoomWrapEl(side, target);
  const zoomer = zoomerEl(side, target);
  if (!wrap || !zoomer) return;
  const key = zoomKey(side, target);
  const s = zoomState[key] ?? { scale: 1, x: 0, y: 0 };
  zoomState[key] = s;
  if (s.scale <= ZOOM_PAN_THRESHOLD) {
    s.x = 0;
    s.y = 0;
  } else {
    [s.x, s.y] = clampPan(s.x, s.y, wrap, s.scale);
  }
  zoomer.style.setProperty("--bb-zoom", String(s.scale));
  zoomer.style.setProperty("--bb-pan-x", `${s.x}px`);
  zoomer.style.setProperty("--bb-pan-y", `${s.y}px`);
  // Zoom-out origin: below 1×, the iframe is enlarged (1/scale × 100%) and
  // must scale around its TOP-LEFT corner so the enlarged viewport maps
  // exactly onto the wrap — zero dead space, zero clipping. At/above 1×
  // use center origin (existing pan clamp is center-based). The switch at
  // scale≈1 is seamless because pan is forced to [0,0] there.
  zoomer.style.transformOrigin = s.scale < 0.99 ? "0 0" : "center center";
  // Zoom-out reflow: below 1×, enlarge the iframe's render viewport by
  // 1/scale so the artifact's content actually reflows into a wider canvas,
  // then the scale transform shrinks it back to fit the wrap. At 0.4× the
  // iframe renders at 250% width — a true overview rather than a tiny
  // clipped version of the same narrow box.
  const frame =
    target === "stage"
      ? el(`stage-frame-${side}`, HTMLIFrameElement)
      : el(`frame-${side}`, HTMLIFrameElement);
  if (frame && s.scale < 0.99) {
    const inv = 1 / s.scale;
    frame.style.width = `${inv * 100}%`;
    frame.style.height = `${inv * 100}%`;
  } else if (frame) {
    frame.style.width = "";
    frame.style.height = "";
  }
  // When zoomed, the wrapper takes pointer capture for pan/pinch; the iframe
  // underneath is paused for inspection (reset to interact again). This keeps
  // drag-to-pan reliable across the iframe boundary without losing the live
  // artifact's state.
  if (s.scale > ZOOM_PAN_THRESHOLD) {
    wrap.classList.add("is-zoomed");
    zoomer.classList.add("is-zoomed");
  } else {
    wrap.classList.remove("is-zoomed");
    zoomer.classList.remove("is-zoomed");
  }
  const label = el(
    target === "stage" ? `stage-zoomlevel-${side}` : `zoomlevel-${side}`,
    HTMLElement
  );
  const live = el(target === "stage" ? `stage-zoomlive-${side}` : `zoomlive-${side}`, HTMLElement);
  const pct = `${Math.round(s.scale * 100)}%`;
  if (label) label.textContent = pct;
  if (live) {
    live.textContent = s.scale > ZOOM_PAN_THRESHOLD ? `Zoom ${pct}. Drag to pan.` : `Zoom ${pct}`;
  }
  const outBtn = el(
    target === "stage" ? `stage-zoomout-${side}` : `zoomout-${side}`,
    HTMLButtonElement
  );
  const inBtn = el(
    target === "stage" ? `stage-zoomin-${side}` : `zoomin-${side}`,
    HTMLButtonElement
  );
  const rstBtn = el(
    target === "stage" ? `stage-zoomreset-${side}` : `zoomreset-${side}`,
    HTMLButtonElement
  );
  if (outBtn) outBtn.disabled = s.scale <= ZOOM_MIN + 0.01;
  if (inBtn) inBtn.disabled = s.scale >= ZOOM_MAX - 0.01;
  if (rstBtn) rstBtn.disabled = Math.abs(s.scale - 1) < 0.001 && s.x === 0 && s.y === 0;
}
function setZoom(
  side: Side,
  target: ZoomTarget,
  next: number,
  focalPoint?: { x: number; y: number }
): void {
  const key = zoomKey(side, target);
  const s = (zoomState[key] ??= { scale: 1, x: 0, y: 0 });
  const oldScale = s.scale;
  const wrap = zoomWrapEl(side, target);
  const nextScale = clampZoom(next);
  if (focalPoint && wrap && oldScale > ZOOM_PAN_THRESHOLD && nextScale > ZOOM_PAN_THRESHOLD) {
    const rect = wrap.getBoundingClientRect();
    const localX = focalPoint.x - (rect.left + rect.width / 2);
    const localY = focalPoint.y - (rect.top + rect.height / 2);
    const contentX = (localX - s.x) / oldScale;
    const contentY = (localY - s.y) / oldScale;
    s.scale = nextScale;
    s.x = localX - contentX * nextScale;
    s.y = localY - contentY * nextScale;
  } else {
    s.scale = nextScale;
  }
  if (s.scale <= ZOOM_PAN_THRESHOLD) {
    s.x = 0;
    s.y = 0;
  }
  applyZoom(side, target);
}
function resetZoom(side: Side, target: ZoomTarget): void {
  zoomState[zoomKey(side, target)] = { scale: 1, x: 0, y: 0 };
  const frame =
    target === "stage"
      ? el(`stage-frame-${side}`, HTMLIFrameElement)
      : el(`frame-${side}`, HTMLIFrameElement);
  if (frame) {
    frame.style.width = "";
    frame.style.height = "";
  }
  applyZoom(side, target);
}
function resetAllZoom(): void {
  for (const side of ["a", "b"] as const) {
    for (const target of ["inline", "stage"] as const) resetZoom(side, target);
  }
}
function wireZoomControls(): void {
  for (const side of ["a", "b"] as const) {
    for (const target of ["inline", "stage"] as const) {
      const key = zoomKey(side, target);
      zoomState[key] ??= { scale: 1, x: 0, y: 0 };
      const wrap = zoomWrapEl(side, target);
      const zoomer = zoomerEl(side, target);
      if (!wrap || !zoomer) continue;

      const outId = target === "stage" ? `stage-zoomout-${side}` : `zoomout-${side}`;
      const inId = target === "stage" ? `stage-zoomin-${side}` : `zoomin-${side}`;
      const rstId = target === "stage" ? `stage-zoomreset-${side}` : `zoomreset-${side}`;
      el(outId, HTMLButtonElement)?.addEventListener("click", () =>
        setZoom(side, target, (zoomState[key]?.scale ?? 1) - ZOOM_STEP)
      );
      el(inId, HTMLButtonElement)?.addEventListener("click", () =>
        setZoom(side, target, (zoomState[key]?.scale ?? 1) + ZOOM_STEP)
      );
      el(rstId, HTMLButtonElement)?.addEventListener("click", () => resetZoom(side, target));

      // Wheel+meta/ctrl to zoom (very common desktop expectation). Plain wheel
      // scrolls the page — only with a modifier do we take over.
      wrap.addEventListener(
        "wheel",
        (e) => {
          if (!(e.metaKey || e.ctrlKey)) return;
          // Don't steal the artifact's own scroll when zoomed out and the
          // artifact is still shielded — but once live, wheel+mod should zoom.
          e.preventDefault();
          const delta = -Math.sign(e.deltaY) * 0.075;
          setZoom(side, target, (zoomState[key]?.scale ?? 1) + delta, {
            x: e.clientX,
            y: e.clientY
          });
        },
        { passive: false }
      );

      // Double-click / double-tap to reset.
      wrap.addEventListener("dblclick", (e) => {
        e.preventDefault();
        resetZoom(side, target);
      });

      // Drag to pan when zoomed. Pointer Events covers mouse+touch+pen in one.
      let dragging = false;
      let sx = 0;
      let sy = 0;
      let ox = 0;
      let oy = 0;
      const pointers = new Map<number, { x: number; y: number }>();
      let pinchStartDist = 0;
      let pinchStartScale = 1;
      let pinchStartMidX = 0;
      let pinchStartMidY = 0;
      let pinchContentX: number | null = null;
      let pinchContentY: number | null = null;

      wrap.addEventListener("pointerdown", (e) => {
        // Toolbar buttons handle their own clicks.
        if (
          e.target instanceof Element &&
          e.target.closest(
            ".bb-zoom-btn, .bb-arena__tool, .bb-arena__play, .bb-arena__zoombar, .bb-stage__zoombar"
          )
        )
          return;
        const st = zoomState[key];
        if (!st) return;
        pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
        try {
          wrap.setPointerCapture(e.pointerId);
        } catch {}
        if (pointers.size === 2) {
          const [first, second] = [...pointers.values()];
          if (!first || !second) return;
          const dx = first.x - second.x;
          const dy = first.y - second.y;
          pinchStartDist = Math.hypot(dx, dy);
          pinchStartScale = st.scale;
          pinchStartMidX = (first.x + second.x) / 2;
          pinchStartMidY = (first.y + second.y) / 2;
          const rect = wrap.getBoundingClientRect();
          pinchContentX =
            (pinchStartMidX - (rect.left + rect.width / 2) - st.x) / Math.max(st.scale, ZOOM_MIN);
          pinchContentY =
            (pinchStartMidY - (rect.top + rect.height / 2) - st.y) / Math.max(st.scale, ZOOM_MIN);
          dragging = false;
          zoomer.classList.remove("is-dragging");
          return;
        }
        if (pointers.size !== 1) return;
        dragging = st.scale > ZOOM_PAN_THRESHOLD;
        sx = e.clientX;
        sy = e.clientY;
        ox = st.x;
        oy = st.y;
        if (dragging) {
          zoomer.classList.add("is-dragging");
          e.preventDefault();
        }
      });
      wrap.addEventListener("pointermove", (e) => {
        if (!pointers.has(e.pointerId)) return;
        pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
        const st = zoomState[key];
        if (!st) return;
        if (pointers.size === 2 && pinchStartDist > 0) {
          const [first, second] = [...pointers.values()];
          if (!first || !second) return;
          const dx = first.x - second.x;
          const dy = first.y - second.y;
          const d = Math.hypot(dx, dy);
          const next = clampZoom(pinchStartScale * (d / pinchStartDist));
          st.scale = next;
          if (pinchContentX !== null && pinchContentY !== null && next > ZOOM_PAN_THRESHOLD) {
            const rect = wrap.getBoundingClientRect();
            const midX = (first.x + second.x) / 2;
            const midY = (first.y + second.y) / 2;
            st.x = midX - (rect.left + rect.width / 2) - pinchContentX * next;
            st.y = midY - (rect.top + rect.height / 2) - pinchContentY * next;
          } else if (next <= ZOOM_PAN_THRESHOLD) {
            st.x = 0;
            st.y = 0;
          }
          applyZoom(side, target);
          return;
        }
        if (!dragging || st.scale <= ZOOM_PAN_THRESHOLD) return;
        const nx = ox + (e.clientX - sx);
        const ny = oy + (e.clientY - sy);
        [st.x, st.y] = clampPan(nx, ny, wrap, st.scale);
        zoomer.style.setProperty("--bb-pan-x", `${st.x}px`);
        zoomer.style.setProperty("--bb-pan-y", `${st.y}px`);
      });
      const endPointer = (e: PointerEvent): void => {
        pointers.delete(e.pointerId);
        if (pointers.size < 2) {
          pinchStartDist = 0;
          pinchContentX = null;
          pinchContentY = null;
        }
        if (pointers.size === 0) {
          dragging = false;
          zoomer.classList.remove("is-dragging");
        } else if (pointers.size === 1) {
          // Back to single-pointer pan; re-anchor from current pan.
          const st = zoomState[key];
          const remaining = [...pointers.values()][0];
          if (st && remaining) {
            sx = remaining.x;
            sy = remaining.y;
            ox = st.x;
            oy = st.y;
            dragging = st.scale > 1.01;
            if (dragging) zoomer.classList.add("is-dragging");
          }
        }
        try {
          wrap.releasePointerCapture(e.pointerId);
        } catch {}
      };
      wrap.addEventListener("pointerup", endPointer);
      wrap.addEventListener("pointercancel", endPointer);

      applyZoom(side, target);
    }
  }
}

/** Toggle every voting surface (per-pane vote bars + the tie row). */
function setVoteUi(visible: boolean): void {
  document.querySelectorAll<HTMLElement>(".bb-arena__voteui").forEach((node) => {
    node.hidden = !visible;
  });
}

/**
 * Deal a fresh pairing.
 *
 * @param reason Replaces the default "dealing" status while the serve is in
 *   flight. This is not decoration: when a spent ballot triggers a re-deal,
 *   the explanation has to BE the loading line or it is never seen — this
 *   function's first act is to overwrite the status, synchronously, so a
 *   caller that sets its own message first is writing to a dead pixel.
 */
async function loadMatchup(reason?: string): Promise<void> {
  setStatus(reason ?? "Dealing a blind matchup…");
  resetStage();
  resetAllZoom();
  lastChoice = null;
  // The rubric judges these two artifacts and nothing else — a fresh pair
  // starts unscored, never inheriting the previous pair's verdicts.
  clearRubric();
  // A fresh pair starts inert: the previous artifacts must not keep the
  // keyboard, and the played signal is per matchup.
  played.a = false;
  played.b = false;
  deactivateFrame("a");
  deactivateFrame("b");
  const frameA = el("frame-a", HTMLIFrameElement);
  const frameB = el("frame-b", HTMLIFrameElement);
  const reveal = el("arena-reveal", HTMLElement);
  const brief = el("arena-brief", HTMLElement);
  if (reveal) reveal.hidden = true;
  setVoteUi(true);
  if (brief) brief.hidden = true;

  try {
    const res = await withTimeout(arenaMatchup({ schemaVersion: 1 }), CALLABLE_TIMEOUT_MS);
    current = res.data;
    const bundles = servedSides(current);
    if (frameA) frameA.src = bundleUrl(bundles.a.bundleId, bundles.a.entry);
    if (frameB) frameB.src = bundleUrl(bundles.b.bundleId, bundles.b.entry);
    renderBrief(current.task);
    setStatus("Two anonymized artifacts. Press play on each, use them for real, then vote.");
    flushPendingVote();
  } catch (err) {
    current = null;
    setStatus(matchupFailureMessage(err));
  }
}

/**
 * Turn a failed serve into something the voter can act on.
 *
 * `failed-precondition` is the interesting one: the callable raises it for
 * three different situations that want three different sentences — an empty
 * registry, a voter who has exhausted the pool, and (via the vote path) a
 * spent ballot. The server already writes that sentence, in voter-facing
 * prose, so this renders the server's message rather than guessing which case
 * fired and getting it wrong two times in three. It is set as `textContent`,
 * so it is copy, never markup.
 *
 * Note this reads `error.code`. The previous `err.message.includes(
 * "failed-precondition")` matched nothing — the message is the prose — so
 * every empty-registry serve told the voter they were rate-limited.
 */
export function matchupFailureMessage(err: unknown): string {
  const code = callableErrorCode(err);
  if (code === "failed-precondition") {
    const message = err instanceof Error ? err.message.trim() : "";
    return message || "No Arena matchups are published yet. The first round is being staged.";
  }
  if (code === "resource-exhausted") {
    return "You're loading pairings faster than we can deal them. Give it a moment.";
  }
  if (code === "deadline-exceeded") {
    return "Dealing a matchup timed out. Check your connection and retry.";
  }
  return "Could not load a matchup. You may be rate-limited; wait a moment and retry.";
}

function renderReveal(revealData: VoteResponse["reveal"]): void {
  const reveal = el("arena-reveal", HTMLElement);
  const cardA = el("reveal-card-a", HTMLElement);
  const cardB = el("reveal-card-b", HTMLElement);
  const build = (sideLabel: string, c: CompetitorReveal, picked: boolean): HTMLElement =>
    buildIdentityCard({
      sideLabel,
      harness: c.harness,
      model: c.model,
      task: c.task,
      trial: `trial ${c.trial}`,
      picked
    });
  // Served orientation in, served orientation out: `reveal.left` is whoever
  // built the artifact the voter was looking at on the left, so it is card A.
  // No flip here, on purpose — see servedSides().
  const identities = servedSides(revealData);
  if (cardA) {
    cardA.replaceChildren(build("Artifact A", identities.a, lastChoice === "A"));
  }
  if (cardB) {
    cardB.replaceChildren(build("Artifact B", identities.b, lastChoice === "B"));
  }
  if (reveal) reveal.hidden = false;
  // The stage tabs may now name names.
  const tabA = stageTab("a");
  const tabB = stageTab("b");
  if (tabA) tabA.textContent = `A · ${identities.a.harness} × ${identities.a.model}`;
  if (tabB) tabB.textContent = `B · ${identities.b.harness} × ${identities.b.model}`;
}

/* ---------- whimsical delight: tiny, cheap, memorable ---------- */

function burstConfetti(origin: HTMLElement | null): void {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const host =
    closestFrom(origin, ".bb-arena__pane, .bb-stage__shell, .bb-arena__reveal", HTMLElement) ??
    query(document, ".bb-arena", HTMLElement);
  const rect = host?.getBoundingClientRect();
  if (!rect) return;
  const canvas = document.createElement("canvas");
  canvas.setAttribute("aria-hidden", "true");
  canvas.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:9999;";
  document.body.appendChild(canvas);
  const maybeCtx = canvas.getContext("2d");
  if (!maybeCtx) {
    canvas.remove();
    return;
  }
  const ctx: CanvasRenderingContext2D = maybeCtx;
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.round(innerWidth * dpr);
  canvas.height = Math.round(innerHeight * dpr);
  canvas.style.width = innerWidth + "px";
  canvas.style.height = innerHeight + "px";
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const cx = rect.left + rect.width / 2;
  const cy = rect.top + rect.height * 0.35;
  const colors =
    ARENA_VARIANT === "neural"
      ? ["#fa6b06", "#ffb020", "#2fd8c4", "#7ff5e6", "#fff6e8"]
      : ["#fa6b06", "#ff8a3d", "#ffb020", "#fff1d6", "#c6ccd6"];
  const parts = Array.from({ length: 22 }, () => ({
    x: cx + (Math.random() - 0.5) * 30,
    y: cy + (Math.random() - 0.5) * 14,
    vx: (Math.random() - 0.5) * 520,
    vy: -Math.random() * 380 - 80,
    r: 3 + Math.random() * 5,
    rot: Math.random() * 360,
    vr: (Math.random() - 0.5) * 520,
    c: at(colors, (Math.random() * colors.length) | 0),
    shape: Math.random() < 0.5 ? "rect" : ("circle" as const)
  }));
  let start = performance.now();
  const dur = 900;
  function tick(now: number): void {
    const t = (now - start) / dur;
    if (t >= 1) {
      canvas.remove();
      return;
    }
    ctx.clearRect(0, 0, innerWidth, innerHeight);
    const grav = 980;
    const dt = 1 / 60;
    for (const p of parts) {
      p.vy += grav * dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.rot += p.vr * dt;
      const a = 1 - t * 0.85;
      ctx.globalAlpha = Math.max(0, a);
      ctx.fillStyle = p.c;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate((p.rot * Math.PI) / 180);
      if (p.shape === "circle") {
        ctx.beginPath();
        ctx.arc(0, 0, p.r, 0, Math.PI * 2);
        ctx.fill();
      } else ctx.fillRect(-p.r, -p.r * 0.55, p.r * 2, p.r * 1.1);
      ctx.restore();
    }
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
}

function wireDelight(): void {
  // VS medallion: click → little spin delight
  for (const sel of [".bb-arena__versus", ".bb-arena__vs"]) {
    document.querySelectorAll(sel).forEach((node) => {
      if (!(node instanceof HTMLElement)) return;
      node.addEventListener("click", () => {
        const el2 = node;
        el2.animate(
          [
            { rotate: "0deg", scale: "1" },
            { rotate: "360deg", scale: "1.18" },
            { rotate: "360deg", scale: "1" }
          ],
          { duration: 520, easing: "cubic-bezier(0.34,1.56,0.64,1)" }
        );
        burstConfetti(el2);
      });
    });
  }
  // Play disc → tiny burst on handover (observe live attribute)
  for (const side of ["a", "b"] as const) {
    const wrap = wrapFor(side);
    if (!wrap) continue;
    new MutationObserver(() => {
      if (wrap.dataset.live === "true") burstConfetti(wrap);
    }).observe(wrap, { attributes: true, attributeFilter: ["data-live"] });
  }
  // Konami-ish: quickly click A ghost then B ghost → filament supernova
  let ghostSeq = 0;
  let ghostTimer = 0;
  for (const side of ["a", "b"] as const) {
    const pane = query(document, `.bb-arena__pane--${side} .bb-arena__ghost`, HTMLElement);
    pane?.addEventListener("click", () => {
      const now = Date.now();
      if (now - ghostTimer > 1400) ghostSeq = 0;
      ghostTimer = now;
      // Expect alternating A, B, A, B
      const expect = ghostSeq % 2 === 0 ? "a" : "b";
      if (side !== expect) {
        ghostSeq = side === "a" ? 1 : 0;
        return;
      }
      ghostSeq++;
      pane.animate(
        [
          { scale: "1", rotate: "0deg" },
          { scale: "1.25", rotate: side === "a" ? "-8deg" : "8deg" },
          { scale: "1", rotate: "0deg" }
        ],
        { duration: 420, easing: "cubic-bezier(0.34,1.56,0.64,1)" }
      );
      if (ghostSeq >= 4) {
        ghostSeq = 0;
        burstConfetti(pane);
        // Extra shimmer: briefly boost filament opacity via CSS var
        const arena = query(document, ".bb-arena", HTMLElement);
        if (arena) {
          arena.style.filter = "brightness(1.18) saturate(1.15)";
          setTimeout(() => {
            arena.style.filter = "";
          }, 700);
        }
      }
    });
  }
  // Trust cells: click → tiny wobble + burst
  document.querySelectorAll(".bb-arena__trust li").forEach((li) => {
    if (!(li instanceof HTMLElement)) return;
    li.style.cursor = "pointer";
    li.addEventListener("click", () => {
      li.animate(
        [
          { transform: "translateY(0) rotate(0deg)" },
          { transform: "translateY(-4px) rotate(0.8deg)" },
          { transform: "translateY(0) rotate(0deg)" }
        ],
        { duration: 380, easing: "ease-out" }
      );
      burstConfetti(li);
    });
  });
}

/* ---------- optional rubric ----------
 * The rubric is pure DOM state until submit. Nothing here can block, delay or
 * fail a vote: readRubric() returns whatever is checked at the moment the
 * voter commits, and an untouched rubric yields undefined — so the request is
 * byte-for-byte the request this page sent before the rubric existed.
 */

function rubricForm(): HTMLFormElement | null {
  return el("arena-rubric", HTMLFormElement);
}

/** The verdicts currently checked, or undefined when the voter skipped it. */
function readRubric(): RubricChoices | undefined {
  const form = rubricForm();
  if (!form) return undefined;
  const choices: RubricChoices = {};
  for (const row of form.querySelectorAll<HTMLElement>("[data-dimension]")) {
    const dimension = row.dataset.dimension ?? "";
    if (!isDimension(dimension)) continue;
    const checked = row.querySelector<HTMLInputElement>("input[type=radio]:checked");
    const value = checked?.value ?? "";
    if (isChoice(value)) choices[dimension] = value;
  }
  return Object.keys(choices).length > 0 ? choices : undefined;
}

/** Re-check the radios for a stored rubric (used after a sign-in redirect). */
function applyRubric(choices: RubricChoices): void {
  const form = rubricForm();
  if (!form) return;
  for (const row of form.querySelectorAll<HTMLElement>("[data-dimension]")) {
    const dimension = row.dataset.dimension ?? "";
    if (!isDimension(dimension)) continue;
    const wanted = choices[dimension];
    for (const input of row.querySelectorAll<HTMLInputElement>("input[type=radio]")) {
      input.checked = input.value === wanted;
    }
  }
  syncRubricClear();
}

function clearRubric(): void {
  rubricForm()?.reset();
  syncRubricClear();
}

/** The clear affordance only exists once there is something to clear. */
function syncRubricClear(): void {
  const button = el("rubric-clear", HTMLButtonElement);
  if (button) button.hidden = readRubric() === undefined;
}

/** The radio for whichever rubric option an event landed in, if any. */
function rubricOptionInput(target: EventTarget | null): HTMLInputElement | null {
  const option = closestFrom(target, ".bb-arena__rubric-opt", HTMLElement);
  return option ? query(option, "input[type=radio]", HTMLInputElement) : null;
}

function wireRubric(): void {
  const form = rubricForm();
  if (!form) return;
  // No action, no submit button — but never let a stray Enter navigate away
  // mid-judgment and lose the matchup.
  form.addEventListener("submit", (event) => event.preventDefault());

  /*
   * Click-to-unset. Native radios cannot be unchecked once set, and every row
   * here is optional, so a voter who decides not to score an axis after all
   * needs a way back to "unjudged".
   *
   * The candidate is captured on pointerdown (before the browser re-checks)
   * and consumed on click, so pressing a checked option and dragging away
   * without releasing changes nothing. The actual uncheck is deferred to a
   * macrotask because a <label> forwards its click to the input, producing a
   * second click whose activation behaviour re-checks it; a task queued from
   * the first click runs strictly after all of that. `setTimeout` rather than
   * `requestAnimationFrame` — rAF is throttled to a standstill in a hidden or
   * backgrounded tab, which would strand the radio checked.
   *
   * Keyboard users are unaffected: Space on an already-checked radio fires no
   * pointerdown, so it never clears, and the explicit "clear" button covers
   * the intent unambiguously.
   */
  let unsetCandidate: HTMLInputElement | null = null;
  form.addEventListener("pointerdown", (event) => {
    const input = rubricOptionInput(event.target);
    unsetCandidate = input?.checked ? input : null;
  });
  form.addEventListener("click", (event) => {
    const input = rubricOptionInput(event.target);
    if (!input || input !== unsetCandidate) {
      unsetCandidate = null;
      return;
    }
    unsetCandidate = null;
    window.setTimeout(() => {
      input.checked = false;
      syncRubricClear();
    }, 0);
  });

  form.addEventListener("change", syncRubricClear);
  el("rubric-clear", HTMLButtonElement)?.addEventListener("click", clearRubric);
  syncRubricClear();
}

/** Bounded analytics shape for how much of the rubric a voter filled in. */
function rubricDepth(choices: RubricChoices | undefined): "none" | "partial" | "full" {
  const filled = choices ? Object.keys(choices).length : 0;
  if (filled === 0) return "none";
  return filled === ARENA_DIMENSIONS.length ? "full" : "partial";
}

/**
 * The exact request body `arenaVote` receives.
 *
 * A type alias rather than an interface so it keeps its implicit index
 * signature and stays assignable to the callable's `Record<string, unknown>`
 * parameter without a cast that would hide a shape mistake.
 */
type VoteWirePayload = {
  schemaVersion: 1;
  matchupId: string;
  serveId: string;
  choice: Choice;
  dimensions?: RubricChoices;
};

/**
 * Build the vote request.
 *
 * `serveId` is mandatory: it is the server's only handle on the orientation
 * this ballot was served in, and a vote without one is rejected outright.
 * `servedSwap` is deliberately absent — the server still tolerates it on the
 * wire so an in-flight old tab is not hard-failed, but it is parsed and thrown
 * away, and sending it would only advertise a claim we have no business
 * making.
 *
 * Extracted so the wire shape is assertable without a DOM, a network or a
 * signed-in user: this is the one thing in the vote path that a reviewer
 * cannot verify by reading the server.
 */
export function buildVotePayload(
  matchup: { matchupId: string; serveId: string },
  choice: Choice,
  dimensions: RubricChoices | undefined
): VoteWirePayload {
  return {
    schemaVersion: 1,
    matchupId: matchup.matchupId,
    serveId: matchup.serveId,
    choice,
    // Omitted entirely when the rubric is untouched: the server treats a
    // missing field and an empty map identically, and the wire stays
    // identical to the pre-rubric request.
    ...(dimensions ? { dimensions } : {})
  };
}

async function submitVote(choice: Choice): Promise<void> {
  if (!current || voting) return;
  const dimensions = readRubric();
  // Soft gate: if signed out, stash the vote and open the sign-in dialog.
  if (!arenaUser) {
    setPendingVote(choice, dimensions);
    openAuthGate();
    return;
  }
  voting = true;
  setStatus("Recording your vote…");
  try {
    const res = await withTimeout(
      arenaVote(buildVotePayload(current, choice, dimensions)),
      CALLABLE_TIMEOUT_MS
    );
    closeStage();
    lastChoice = choice;
    renderReveal(res.data.reveal);
    setVoteUi(false);
    setStatus("Vote recorded. Identities revealed below.");
    trackEvent(EVENT.arenaVoteRecorded, {
      variant: ARENA_VARIANT,
      choice,
      rubric: rubricDepth(dimensions)
    });
    burstConfetti(document.getElementById("arena-reveal"));
  } catch (err) {
    // Classified by `error.code`, never by `error.message` (see
    // callableErrorCode): the old message sniffing matched nothing, so every
    // failure here landed in the generic "please retry" — including the ones
    // a retry can never fix.
    const action = voteFailureAction(err);
    if (action.kind === "refetch") {
      // Spent, expired, mismatched or already-judged ballot. None of these are
      // recoverable by voting again on this pairing, and all of them are fixed
      // by the same thing: deal another one, keeping the voter in flow. The
      // reason travels INTO loadMatchup because loadMatchup's own first line
      // overwrites the status — setting it here would be invisible.
      void loadMatchup(action.status);
    } else if (action.kind === "reauth") {
      // Token expired or revoked mid-session — re-gate, holding the judgment.
      setPendingVote(choice, dimensions);
      openAuthGate();
    } else {
      setStatus(action.status);
    }
  } finally {
    voting = false;
  }
}

/* ---------- auth gate: sign-in dialog ---------- */

function authGateDialog(): HTMLDialogElement | null {
  return el("arena-authgate", HTMLDialogElement);
}

function setAuthGateMessage(message: string): void {
  const node = el("authgate-status", HTMLElement);
  if (!node) return;
  node.textContent = message;
  node.hidden = !message;
}

function setAuthGateBusy(busy: boolean): void {
  document.querySelectorAll<HTMLButtonElement>(".bb-authgate__btn").forEach((button) => {
    button.disabled = busy;
    button.setAttribute("aria-busy", String(busy));
  });
}

function setPendingVote(choice: Choice | null, dimensions?: RubricChoices): void {
  pendingVote = choice;
  pendingRubric = choice ? dimensions : undefined;
  try {
    if (choice) sessionStorage.setItem(PENDING_VOTE_KEY, choice);
    else sessionStorage.removeItem(PENDING_VOTE_KEY);
    // The redirect sign-in flow reloads the page, which wipes the rubric's DOM
    // state. Park it beside the pending choice so a voter who scored four axes
    // and then signed in does not silently lose all four.
    if (choice && dimensions) {
      sessionStorage.setItem(PENDING_RUBRIC_KEY, JSON.stringify(dimensions));
    } else {
      sessionStorage.removeItem(PENDING_RUBRIC_KEY);
    }
  } catch {
    // Session storage is an enhancement; the in-memory vote still works.
  }
}

/** Parse a stored rubric, keeping only entries still in the vocabulary. */
function parseStoredRubric(raw: string): RubricChoices | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return undefined;
  const choices: RubricChoices = {};
  for (const [key, value] of Object.entries<unknown>({ ...parsed })) {
    if (isDimension(key) && typeof value === "string" && isChoice(value)) choices[key] = value;
  }
  return Object.keys(choices).length > 0 ? choices : undefined;
}

function restorePendingVote(): void {
  if (pendingVote !== null) return;
  try {
    const saved = sessionStorage.getItem(PENDING_VOTE_KEY);
    if (saved === "A" || saved === "B" || saved === "tie") pendingVote = saved;
    const savedRubric = sessionStorage.getItem(PENDING_RUBRIC_KEY);
    if (pendingVote !== null && savedRubric) {
      pendingRubric = parseStoredRubric(savedRubric);
      if (pendingRubric) applyRubric(pendingRubric);
    }
  } catch {
    // Storage may be blocked by a privacy mode.
  }
}

function rememberRedirectProvider(provider: ArenaSignInProvider | null): void {
  try {
    if (provider) sessionStorage.setItem(REDIRECT_PROVIDER_KEY, provider);
    else sessionStorage.removeItem(REDIRECT_PROVIDER_KEY);
  } catch {
    // Best-effort analytics context only.
  }
}

function flushPendingVote(): void {
  if (!arenaUser || pendingVote === null || !current || voting) return;
  const choice = pendingVote;
  // Put the stashed rubric back on the ballot before clearing it, so
  // submitVote reads the voter's own scores rather than an empty form.
  if (pendingRubric) applyRubric(pendingRubric);
  setPendingVote(null);
  closeAuthGate();
  void submitVote(choice);
}

function openAuthGate(): void {
  trackEvent(EVENT.arenaAuthGateShown, { variant: ARENA_VARIANT });
  setAuthGateMessage("");
  const dialog = authGateDialog();
  if (dialog && !dialog.open) dialog.showModal();
}

function closeAuthGate(): void {
  const dlg = authGateDialog();
  if (dlg?.open) dlg.close();
  setAuthGateMessage("");
}

/*
 * True when Firebase rejected the origin rather than the sign-in itself.
 *
 * `auth/unauthorized-domain` is the documented case (origin missing from Auth's
 * authorized domains). The referrer case has no constant: the SDK builds the
 * code from the API key's 403 message, yielding e.g.
 * `auth/requests-from-referer-http://localhost:4321/-are-blocked.` — the origin
 * is interpolated into the code itself, so it has to be matched by shape.
 */
function isOriginRejection(code: string): boolean {
  return code === "auth/unauthorized-domain" || /^auth\/requests-from-referer\b/.test(code);
}

async function arenaSignIn(provider: ArenaSignInProvider): Promise<void> {
  const authProvider = arenaProviders[provider];
  setAuthGateBusy(true);
  setAuthGateMessage(`Opening ${arenaProviderLabels[provider]} sign-in…`);
  try {
    const credential = await signInWithPopup(arenaAuth, authProvider);
    trackEvent(EVENT.arenaSignInCompleted, { variant: ARENA_VARIANT, provider });
    trackEmailCapturedIfNewAccount(credential.user, provider);
  } catch (err) {
    const code = callableErrorCode(err);
    // The referrer-blocked code below is synthesized from the server's message,
    // so it never matches a documented constant. Log it or it is unknowable.
    console.warn("[arena] sign-in failed", provider, code);
    // Popup blocked → fall back to redirect (preserves the vote intent via
    // pendingVote, which survives the redirect because onAuthStateChanged
    // fires on return and auto-submits).
    if (code === "auth/popup-blocked") {
      rememberRedirectProvider(provider);
      setAuthGateMessage("The sign-in window was blocked. Continuing in this tab…");
      try {
        await signInWithRedirect(arenaAuth, authProvider);
      } catch {
        rememberRedirectProvider(null);
        setAuthGateMessage("Sign-in could not open here. Try another provider.");
      }
      return;
    }
    if (isOriginRejection(code)) {
      // Provider-independent: this fires in _validateOrigin, before the chosen
      // provider is ever contacted, so "try another provider" would be a lie.
      setAuthGateMessage(
        `Sign-in isn't authorized from ${location.host}. Open burnbar.ai to cast your vote.`
      );
    } else if (code === "auth/account-exists-with-different-credential") {
      setAuthGateMessage(
        "That email already has a BurnBench account. Use the provider you signed in with originally."
      );
    } else if (code === "auth/operation-not-allowed") {
      setAuthGateMessage("That sign-in option is not configured yet. Try Google or Apple.");
    } else if (code === "auth/network-request-failed") {
      setAuthGateMessage("The sign-in connection failed. Check your network and try again.");
    } else if (code !== "auth/cancelled-popup-request" && code !== "auth/popup-closed-by-user") {
      setStatus("Sign-in didn't complete. Try again when you're ready.");
      setAuthGateMessage("Sign-in didn't complete. Try again when you're ready.");
    } else {
      setAuthGateMessage("");
    }
  } finally {
    setAuthGateBusy(false);
  }
}

function arenaSignOut(): void {
  void signOut(arenaAuth);
}

/** Render the signed-in chip (email + sign-out) or hide it when anonymous. */
function renderAuthChip(): void {
  const chip = el("arena-auth-chip", HTMLElement);
  if (!chip) return;
  if (arenaUser) {
    chip.hidden = false;
    const provider = arenaUser.providerData[0]?.providerId
      ?.replace(".com", "")
      .replace("apple", "Apple")
      .replace("google", "Google")
      .replace("github", "GitHub")
      .replace("facebook", "Meta");
    chip.textContent = `judging as ${arenaUser.email ?? provider ?? arenaUser.uid.slice(0, 8)} · fresh pairings only`;
    const signOutBtn = el("arena-signout", HTMLButtonElement);
    if (signOutBtn) signOutBtn.hidden = false;
  } else {
    chip.hidden = true;
    chip.textContent = "";
    const signOutBtn = el("arena-signout", HTMLButtonElement);
    if (signOutBtn) signOutBtn.hidden = true;
  }
}

/** Wire the auth gate buttons and the onAuthStateChanged listener. */
function wireAuthGate(): void {
  restorePendingVote();
  el("authgate-google", HTMLButtonElement)?.addEventListener(
    "click",
    () => void arenaSignIn("google")
  );
  el("authgate-apple", HTMLButtonElement)?.addEventListener(
    "click",
    () => void arenaSignIn("apple")
  );
  el("authgate-github", HTMLButtonElement)?.addEventListener(
    "click",
    () => void arenaSignIn("github")
  );
  el("authgate-meta", HTMLButtonElement)?.addEventListener(
    "click",
    () => void arenaSignIn("facebook")
  );
  el("authgate-dismiss", HTMLButtonElement)?.addEventListener("click", () => {
    setPendingVote(null);
    closeAuthGate();
  });
  el("arena-signout", HTMLButtonElement)?.addEventListener("click", () => arenaSignOut());

  // Click outside the gate panel closes it (same modal-backdrop pattern as the stage).
  authGateDialog()?.addEventListener("click", (event) => {
    if (event.target === authGateDialog()) {
      setPendingVote(null);
      closeAuthGate();
    }
  });

  // onAuthStateChanged: update chip, auto-submit any pending vote.
  onAuthStateChanged(arenaAuth, (user) => {
    arenaUser = user;
    renderAuthChip();
    flushPendingVote();
  });

  // Handle redirect-based sign-in return (popup-blocked fallback).
  getRedirectResult(arenaAuth)
    .then((result) => {
      if (!result?.user) return;
      const provider = sessionStorage.getItem(REDIRECT_PROVIDER_KEY);
      if (provider && provider in arenaProviders) {
        trackEvent(EVENT.arenaSignInCompleted, { variant: ARENA_VARIANT, provider });
        trackEmailCapturedIfNewAccount(result.user, provider);
      }
      rememberRedirectProvider(null);
    })
    .catch(() => {
      // A missing redirect result is normal on a fresh page load.
    });
}

function wire(): void {
  // Before the auth gate: restorePendingVote() may need to repaint a rubric
  // that survived a sign-in redirect.
  wireRubric();
  el("vote-a", HTMLButtonElement)?.addEventListener("click", () => void submitVote("A"));
  el("vote-b", HTMLButtonElement)?.addEventListener("click", () => void submitVote("B"));
  el("vote-tie", HTMLButtonElement)?.addEventListener("click", () => void submitVote("tie"));
  el("arena-next", HTMLButtonElement)?.addEventListener("click", () => void loadMatchup());

  // Live artifacts: the shield hands over control in place; the stage is the
  // same artifact on a bigger canvas, where it owns input until Esc.
  for (const side of ["a", "b"] as const) {
    el(`play-${side}`, HTMLButtonElement)?.addEventListener("click", () => activateFrame(side));
    el(`reload-${side}`, HTMLButtonElement)?.addEventListener("click", () => reloadFrame(side));
  }
  el("expand-a", HTMLButtonElement)?.addEventListener("click", () => openStage("a"));
  el("expand-b", HTMLButtonElement)?.addEventListener("click", () => openStage("b"));
  el("stage-tab-a", HTMLButtonElement)?.addEventListener("click", () => showStageSide("a"));
  el("stage-tab-b", HTMLButtonElement)?.addEventListener("click", () => showStageSide("b"));
  el("stage-prev", HTMLButtonElement)?.addEventListener("click", () =>
    showStageSide(stageSide === "a" ? "b" : "a")
  );
  el("stage-next", HTMLButtonElement)?.addEventListener("click", () =>
    showStageSide(stageSide === "a" ? "b" : "a")
  );
  el("stage-close", HTMLButtonElement)?.addEventListener("click", closeStage);
  // Click-outside: a modal dialog's own box is the backdrop area when the
  // shell doesn't fill it; clicks landing on the dialog itself close it.
  stageDialog()?.addEventListener("click", (event) => {
    if (event.target === stageDialog()) closeStage();
  });
  // Keep local state in sync however the dialog closes (Esc, button, vote).
  stageDialog()?.addEventListener("close", () => {
    stageOpen = false;
    document.body.style.overflow = "";
  });
  el("stage-vote-a", HTMLButtonElement)?.addEventListener("click", () => void submitVote("A"));
  el("stage-vote-b", HTMLButtonElement)?.addEventListener("click", () => void submitVote("B"));

  document.addEventListener("keydown", (event) => {
    if (!stageOpen) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      // When focus is inside an artifact frame the keys belong to the
      // artifact (games steer with arrows); otherwise they switch sides.
      const active = document.activeElement;
      if (active === stageFrame("a") || active === stageFrame("b")) return;
      event.preventDefault();
      showStageSide(stageSide === "a" ? "b" : "a");
    }
  });

  // Zoom keys: when a zoomwrap or stage zoomwrap has focus, +/- zoom and
  // 0 resets. The live artifact correctly keeps arrow keys; zoom keeps these.
  document.addEventListener("keydown", (event) => {
    const inZoom = !!closestFrom(
      event.target,
      ".bb-arena__zoomwrap, .bb-stage__zoomwrap, .bb-arena__zoombar, .bb-stage__zoombar",
      HTMLElement
    );
    const focused = targetAs(event.target, HTMLElement);
    const typing = !!focused && /INPUT|TEXTAREA|SELECT/.test(focused.tagName);
    const mod = event.metaKey || event.ctrlKey;
    if (event.key === "+" || event.key === "=") {
      if (!inZoom && !mod) return;
      // Don't hijack typing in inputs.
      if (typing) return;
      event.preventDefault();
      const side: Side = stageOpen
        ? stageSide
        : document.activeElement?.closest("#wrap-b, #stage-zoomwrap-b")
          ? "b"
          : "a";
      const target: ZoomTarget = stageOpen ? "stage" : "inline";
      setZoom(side, target, (zoomState[zoomKey(side, target)]?.scale ?? 1) + ZOOM_STEP);
    } else if (event.key === "-" || event.key === "_") {
      if (!inZoom && !mod) return;
      if (typing) return;
      event.preventDefault();
      const side: Side = stageOpen
        ? stageSide
        : document.activeElement?.closest("#wrap-b, #stage-zoomwrap-b")
          ? "b"
          : "a";
      const target: ZoomTarget = stageOpen ? "stage" : "inline";
      setZoom(side, target, (zoomState[zoomKey(side, target)]?.scale ?? 1) - ZOOM_STEP);
    } else if (event.key === "0" && (inZoom || mod)) {
      if (typing && !mod) return;
      event.preventDefault();
      const side: Side = stageOpen
        ? stageSide
        : document.activeElement?.closest("#wrap-b, #stage-zoomwrap-b")
          ? "b"
          : "a";
      const target: ZoomTarget = stageOpen ? "stage" : "inline";
      resetZoom(side, target);
    } else if (event.key === "Escape" && !stageOpen) {
      // Esc outside the stage resets any zoomed pane — cheap undo.
      let any = false;
      for (const k of Object.keys(zoomState)) if ((zoomState[k]?.scale ?? 1) > 1.01) any = true;
      if (any) {
        resetAllZoom();
        event.preventDefault();
      }
    }
  });

  wireZoomControls();
  wireDelight();
  wireAuthGate();
  initVariantExperiment();
  void loadMatchup();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", wire, { once: true });
} else {
  wire();
}
