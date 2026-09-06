/**
 * @fileoverview Machine-readable refusal reasons for the team roster lane (D16 / P22).
 *
 * THE DEFECT THIS CLOSES. Every roster callable used to refuse with a bare
 * `HttpsError(code, message)` and no `details`, and several DIFFERENT causes
 * share one status code — `promoteTeamMember` alone can raise eight distinct
 * `failed-precondition`s. The Mac app therefore had to tell two of them apart by
 * matching substrings of the server's English message ("escrow device",
 * "pending member can be promoted"), so a server-side reword silently changed
 * what an admin was told. That is a text contract across a network boundary; the
 * shipped comment in `AgentLens/Services/CloudSync/TeamRosterDirectory.swift`
 * named this file's `details.reason` as the real fix.
 *
 * THE CONTRACT. Every `HttpsError` thrown by `./teamRoster.ts`,
 * `./teamRosterState.ts`, `./teamKeyEnvelopes.ts` and
 * `./callables/teamRosterCallables.ts` is raised through {@link rosterError} and
 * carries `details: { reason: <one of the codes below> }`. The status code and
 * the human message are UNCHANGED — the message is what an operator reads in a
 * log, and it may carry a uid, an email or a document id, which is exactly why
 * it must never be the thing a client switches on.
 *
 * WHAT IS AND IS NOT COVERED. Every refusal the ROSTER AUTHORITY decides — the
 * eight callables, their payload validation, the envelope-coverage helpers and
 * the state guard — carries a reason. The generic validators in
 * `./callables/shared/validators.ts` are shared with the whole callable surface
 * and still raise bare `HttpsError`s; the roster callables therefore re-raise
 * them through {@link withRosterReason} so that a malformed roster payload is
 * still a reasoned refusal. The cross-cutting guards ABOVE the authority —
 * App Check, `checkTeam*RateLimit`, `assertActiveBurnBarCloudProEntitlement` —
 * deliberately keep their own errors: they are not roster decisions, they carry
 * their own status codes (`resource-exhausted`, `permission-denied`), and
 * relabelling them as roster reasons would be a false claim about who refused.
 * A client that sees no reason renders its generic copy, which is the honest
 * outcome for all three.
 *
 * `details` carries the reason AND NOTHING ELSE. Anything more is a field the
 * client did not ask for on an error path; the reason is a closed enumeration
 * that leaks nothing the caller who triggered the refusal did not already know.
 *
 * THE STATUS CODE LIVES WITH THE REASON, not at the throw site. Each refusal has
 * exactly one gRPC status — it is a property of the cause, not of the line that
 * raises it — so declaring the pair once makes it impossible for two sites that
 * share a reason to disagree about the code a client sees, and keeps every throw
 * site the same length it was before this change (`./teamRoster.ts` has 11 lines
 * of headroom under the 600-line lint ceiling).
 *
 * ONE CODE PER CAUSE, and a cause raised at two sites for the same reason shares
 * one code (an invite re-checked inside its burn transaction is the SAME
 * "already used" as the cheap pre-check). Two entries are deliberately MERGED
 * causes, and both say so where they are declared:
 * {@link TEAM_ROSTER_REASON.INVITE_NOT_VALID_FOR_ACCOUNT} and
 * {@link TEAM_ROSTER_REASON.ALREADY_ON_THIS_TEAM}.
 *
 * THE CLIENT MIRROR is `TeamRosterReasonCode` in
 * `AgentLens/Services/CloudSync/TeamRosterDirectory.swift`, and
 * `scripts/ci/verify-team-roster-reason-codes.sh` fails the build when the two
 * enumerations disagree in either direction — so a code added here without a
 * Swift case, or a Swift case for a code that no longer exists, is caught before
 * it ships rather than degrading to generic copy in the field. That gate also
 * refuses a reason declared here and thrown nowhere, so this list stays a
 * description of the server's real refusals rather than an aspiration.
 */

import { HttpsError, type FunctionsErrorCode } from "firebase-functions/v2/https";

/** One refusal: the gRPC status a client sees and the stable machine-readable cause. */
interface TeamRosterRefusal {
  code: FunctionsErrorCode;
  reason: string;
}

/**
 * The closed set of machine-readable roster refusals.
 *
 * `reason` values are stable wire constants. RENAMING ONE IS A BREAKING CHANGE
 * for every shipped Mac app: an older client that does not know a code falls
 * through to its generic "nothing was shared, try again" copy, which is honest
 * but strictly less useful. Add codes; do not repurpose them. The key and the
 * `reason` are always the same string — the CI mirror gate enforces that too, so
 * a grep for either finds the throw sites.
 */
export const TEAM_ROSTER_REASON = {
  // ── Callable payload validation (./callables/teamRosterCallables.ts) ──────
  /** No verified Firebase Auth uid on the request. */
  UNAUTHENTICATED: { code: "unauthenticated", reason: "UNAUTHENTICATED" },
  /** `teamId` is absent, over-long, or not `^team_[a-z0-9]{16}$` — the shape the memory engine parses. */
  INVALID_TEAM_ID: { code: "invalid-argument", reason: "INVALID_TEAM_ID" },
  /** `name` is absent or longer than a team name may be. */
  INVALID_TEAM_NAME: { code: "invalid-argument", reason: "INVALID_TEAM_NAME" },
  /** A uid argument (`uid` / `targetUid`) is not an account identifier. */
  INVALID_ACCOUNT_ID: { code: "invalid-argument", reason: "INVALID_ACCOUNT_ID" },
  /** `role` is neither "admin" nor "member". */
  INVALID_ROLE: { code: "invalid-argument", reason: "INVALID_ROLE" },
  /** `inviteeEmail` is not an email address. */
  INVALID_INVITEE_EMAIL: { code: "invalid-argument", reason: "INVALID_INVITEE_EMAIL" },
  /** An entry of `envelopeIds` is not a usable document id. */
  INVALID_ENVELOPE_ID: { code: "invalid-argument", reason: "INVALID_ENVELOPE_ID" },
  /** `envelopeIds` is not an array, or names more envelopes than one call may claim. */
  INVALID_ENVELOPE_IDS: { code: "invalid-argument", reason: "INVALID_ENVELOPE_IDS" },
  /** A key-version argument is not a number inside the range the roster accepts. */
  INVALID_KEY_VERSION: { code: "invalid-argument", reason: "INVALID_KEY_VERSION" },
  /** `inviteToken` is not `^inv_[A-Za-z0-9_-]{32,64}$` — refused before it is hashed. */
  INVALID_INVITE_TOKEN: { code: "invalid-argument", reason: "INVALID_INVITE_TOKEN" },
  /** `rewrapJobId` is not the bounded correlation handle the team document stores. */
  INVALID_REWRAP_JOB_ID: { code: "invalid-argument", reason: "INVALID_REWRAP_JOB_ID" },

  // ── Caller authority (./teamRoster.ts) ────────────────────────────────────
  /** The caller has no row at all on this roster. */
  CALLER_NOT_A_TEAM_MEMBER: { code: "permission-denied", reason: "CALLER_NOT_A_TEAM_MEMBER" },
  /** The caller has a row, but is not an `active` `admin`. */
  CALLER_NOT_AN_ACTIVE_ADMIN: { code: "permission-denied", reason: "CALLER_NOT_AN_ACTIVE_ADMIN" },

  // ── The caller's own escrow devices (./teamRoster.ts) ─────────────────────
  /**
   * The caller published no trusted escrow device whose key version and
   * fingerprint are both pinnable, so nothing can ever be wrapped for them.
   * Raised by `createTeam` (the founder is pinned exactly as a joiner is) and by
   * `acceptTeamInvite`. Distinct from
   * {@link TEAM_ROSTER_REASON.MEMBER_HAS_NO_TRUSTED_ESCROW_DEVICE}, which is
   * about the PROMOTION TARGET and reaches a different person's copy.
   */
  CALLER_HAS_NO_TRUSTED_ESCROW_DEVICE: { code: "failed-precondition", reason: "CALLER_HAS_NO_TRUSTED_ESCROW_DEVICE" },
  /** The caller pins more trusted devices than one member may hold team keys on. */
  CALLER_HAS_TOO_MANY_TRUSTED_DEVICES: { code: "failed-precondition", reason: "CALLER_HAS_TOO_MANY_TRUSTED_DEVICES" },

  // ── Invites (./teamRoster.ts) ─────────────────────────────────────────────
  /** No OpenBurnBar account exists for the invitee's email address. */
  INVITEE_HAS_NO_ACCOUNT: { code: "failed-precondition", reason: "INVITEE_HAS_NO_ACCOUNT" },
  /** The admin addressed the invite to their own uid. */
  CANNOT_INVITE_YOURSELF: { code: "invalid-argument", reason: "CANNOT_INVITE_YOURSELF" },
  /** The invitee already holds a live (non-`removed`) row on this team. */
  INVITEE_ALREADY_ON_TEAM: { code: "already-exists", reason: "INVITEE_ALREADY_ON_TEAM" },
  /** The accepting caller's email address is not verified. */
  EMAIL_NOT_VERIFIED: { code: "permission-denied", reason: "EMAIL_NOT_VERIFIED" },
  /**
   * DELIBERATELY ONE CODE FOR TWO CAUSES: the invite document does not exist,
   * and the invite exists but is bound to somebody else's uid. The server words
   * both identically on purpose — separating them would turn `acceptTeamInvite`
   * into an oracle for "is this token real", which is the whole point of storing
   * only `sha256(token)` and binding the invite to a uid at issue time.
   * Splitting the REASON would rebuild that oracle in a field a client can read,
   * so this is a merge the security model requires, not an omission.
   */
  INVITE_NOT_VALID_FOR_ACCOUNT: { code: "permission-denied", reason: "INVITE_NOT_VALID_FOR_ACCOUNT" },
  /** The invite is not `pending` any more — single use, and it has been used. */
  INVITE_ALREADY_USED: { code: "failed-precondition", reason: "INVITE_ALREADY_USED" },
  /** The invite is past its 7-day expiry (and has just been stamped `expired`). */
  INVITE_EXPIRED: { code: "failed-precondition", reason: "INVITE_EXPIRED" },
  /**
   * The accepting caller already holds a live row on this team. ONE CODE FOR THE
   * CHEAP PRE-CHECK AND THE TRANSACTIONAL RE-CHECK: they are the same refusal,
   * and the second exists only because the first is not the authority.
   */
  ALREADY_ON_THIS_TEAM: { code: "already-exists", reason: "ALREADY_ON_THIS_TEAM" },

  // ── Promotion and removal (./teamRoster.ts, ./teamRosterState.ts) ─────────
  /** `promoteTeamMember`: the target has no roster row, so no invite was accepted. */
  MEMBER_HAS_NOT_ACCEPTED_INVITE: { code: "not-found", reason: "MEMBER_HAS_NOT_ACCEPTED_INVITE" },
  /**
   * `promoteTeamMember`: the target row exists but is not `pending` — already
   * active, suspended, or removed while this admin was wrapping. Raised by the
   * cheap pre-check and again by `commitGuardedByTeamState`'s in-transaction
   * re-read; one cause, one code.
   */
  MEMBER_NOT_PENDING: { code: "failed-precondition", reason: "MEMBER_NOT_PENDING" },
  /** `promoteTeamMember`: the target pins no escrow device, so coverage cannot be built. */
  MEMBER_HAS_NO_TRUSTED_ESCROW_DEVICE: { code: "failed-precondition", reason: "MEMBER_HAS_NO_TRUSTED_ESCROW_DEVICE" },
  /** `removeTeamMember`: no row, or a row already `removed`. Both checks, one cause. */
  MEMBER_NOT_FOUND_IN_TEAM: { code: "not-found", reason: "MEMBER_NOT_FOUND_IN_TEAM" },
  /** `removeTeamMember`: evicting this member would leave the team with no active admin. */
  LAST_ACTIVE_ADMIN: { code: "failed-precondition", reason: "LAST_ACTIVE_ADMIN" },

  // ── Key generations (./teamRoster.ts) ─────────────────────────────────────
  /** `abandonTeamKeyGeneration`: the version is the active one, or is retained. */
  KEY_VERSION_STILL_RECORDED: { code: "failed-precondition", reason: "KEY_VERSION_STILL_RECORDED" },
  /** `abandonTeamKeyGeneration`: the version is not the next unclaimed one. */
  KEY_VERSION_NOT_NEXT_UNCLAIMED: { code: "invalid-argument", reason: "KEY_VERSION_NOT_NEXT_UNCLAIMED" },
  /** `abandonTeamKeyGeneration`: no envelope was ever published for that version. */
  NO_ABANDONED_ROTATION_TO_BURN: { code: "failed-precondition", reason: "NO_ABANDONED_ROTATION_TO_BURN" },
  /** `rotateTeamKey`: `newKeyVersion` is not the next non-burned version. */
  KEY_VERSION_NOT_SEQUENTIAL: { code: "invalid-argument", reason: "KEY_VERSION_NOT_SEQUENTIAL" },
  /** `rotateTeamKey`: the next version would exceed what `firestore.rules` accepts. */
  KEY_VERSIONS_EXHAUSTED: { code: "failed-precondition", reason: "KEY_VERSIONS_EXHAUSTED" },
  /** `rotateTeamKey`: an ACTIVE member pins no device, so the rotation cannot cover them. */
  ACTIVE_MEMBER_HAS_NO_PINNED_DEVICE: { code: "failed-precondition", reason: "ACTIVE_MEMBER_HAS_NO_PINNED_DEVICE" },
  /** `recordTeamRewrapComplete`: the completion names a generation that is not current. */
  REWRAP_KEY_VERSION_NOT_CURRENT: { code: "failed-precondition", reason: "REWRAP_KEY_VERSION_NOT_CURRENT" },

  // ── Envelope coverage (./teamKeyEnvelopes.ts) ─────────────────────────────
  /** More envelopes are required than one call may verify. */
  TOO_MANY_KEY_ENVELOPES: { code: "failed-precondition", reason: "TOO_MANY_KEY_ENVELOPES" },
  /** The caller did not claim every required envelope id. */
  KEY_ENVELOPE_COVERAGE_INCOMPLETE: { code: "failed-precondition", reason: "KEY_ENVELOPE_COVERAGE_INCOMPLETE" },
  /** A claimed envelope document does not exist yet. */
  KEY_ENVELOPE_NOT_PUBLISHED: { code: "failed-precondition", reason: "KEY_ENVELOPE_NOT_PUBLISHED" },
  /** A published envelope names a different (uid, device, escrow key version, slot). */
  KEY_ENVELOPE_ADDRESSED_ELSEWHERE: { code: "failed-precondition", reason: "KEY_ENVELOPE_ADDRESSED_ELSEWHERE" },
  /** A published envelope is wrapped to a key the recipient never published. */
  KEY_ENVELOPE_WRAPPED_TO_UNKNOWN_KEY: { code: "failed-precondition", reason: "KEY_ENVELOPE_WRAPPED_TO_UNKNOWN_KEY" },
  /** A published envelope's `wrappedBy` is neither a team admin nor its recipient. */
  KEY_ENVELOPE_WRAPPER_NOT_AUTHORIZED: { code: "failed-precondition", reason: "KEY_ENVELOPE_WRAPPER_NOT_AUTHORIZED" },

  // ── Team document and in-flight state (./teamRosterState.ts) ──────────────
  /** The team document does not exist. */
  TEAM_NOT_FOUND: { code: "not-found", reason: "TEAM_NOT_FOUND" },
  /** The team document exists but carries no usable key state. */
  TEAM_KEY_STATE_MISSING: { code: "failed-precondition", reason: "TEAM_KEY_STATE_MISSING" },
  /**
   * `commitGuardedByTeamState` re-read the team inside the writing transaction
   * and the KEY state or the MEMBERSHIP epoch had moved, so the decision this
   * call computed is stale and the retry is against a fresh snapshot. This is
   * the only `aborted` the lane raises.
   */
  ROSTER_STATE_MOVED_IN_FLIGHT: { code: "aborted", reason: "ROSTER_STATE_MOVED_IN_FLIGHT" },
} as const satisfies Record<string, TeamRosterRefusal>;

/**
 * The ONLY way this lane raises an `HttpsError`.
 *
 * Same status code, same human message, plus `details.reason`. A factory rather
 * than a subclass so a throw site stays exactly as long as it was.
 */
export function rosterError(refusal: TeamRosterRefusal, message: string): HttpsError {
  return new HttpsError(refusal.code, message, { reason: refusal.reason });
}

/**
 * Run a shared validator and re-raise its bare refusal as a reasoned one.
 *
 * `./callables/shared/validators.ts` is used by every callable in the codebase,
 * so it cannot carry this lane's reasons — but a roster callable that refuses
 * "teamId is required." with no reason is exactly the unstructured refusal this
 * module exists to remove. The MESSAGE is kept verbatim (it names the field an
 * operator has to fix) and the caller supplies the reason for the field it was
 * reading.
 *
 * ONLY A REASONLESS `HttpsError` IS RE-LABELLED. Anything already carrying
 * `details` is passed through untouched, so a nested roster refusal keeps its
 * own, more specific reason instead of being overwritten by the outer field's.
 */
export function withRosterReason<T>(refusal: TeamRosterRefusal, read: () => T): T {
  try {
    return read();
  } catch (error) {
    if (error instanceof HttpsError && error.details === undefined) {
      throw rosterError(refusal, error.message);
    }
    throw error;
  }
}
