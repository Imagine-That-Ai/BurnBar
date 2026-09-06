/**
 * @fileoverview Callable surface for the team roster authority (D16 / P21).
 *
 * Every payload is validated here and nothing else reaches
 * {@link TeamRosterService}: a team id must match the shape the memory engine
 * parses, an invite token must look like one before it is hashed and looked
 * up, and no callable anywhere on this surface accepts a client-supplied
 * escrow public key.
 *
 * EVERY REFUSAL HERE CARRIES A REASON (D16 / P22). The validators in
 * `./shared/validators.js` are shared with the whole callable surface and raise
 * bare `HttpsError`s, so each call into them is wrapped in `withRosterReason`
 * with the reason for the FIELD being read — the message is kept verbatim and
 * the client gets a code to switch on instead of English to match. See
 * `../teamRosterReasons.js` for the enumeration and for what is deliberately
 * left unreasoned (App Check, rate limits, the entitlement check).
 */

import { type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { TEAM_ROSTER_REASON as REASON, rosterError, withRosterReason } from "../teamRosterReasons.js";
import {
  INVITE_TOKEN_PATTERN,
  MAX_ENVELOPE_IDS,
  MAX_REWRAP_JOB_ID_LENGTH,
  MAX_TEAM_KEY_VERSION,
  TEAM_ID_PATTERN,
  TeamRosterService,
} from "../teamRoster.js";
import { SLUG_KEY_ID_PATTERN, recordTeamSlugKeyId as recordSlugKeyId } from "../teamSlugKeyRecord.js";
import { boundedTrimmedString, requireBoundedNumber, requireBoundedStringArray } from "./shared/validators.js";
import {
  checkTeamInviteAcceptRateLimit,
  checkTeamInviteRateLimit,
  checkTeamRosterMutationRateLimit,
} from "./publicRateLimit.js";

function requireAuthUid(request: CallableRequest<unknown>): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw rosterError(REASON.UNAUTHENTICATED, "Sign in before managing a team.");
  }
  return uid;
}

function requireTeamId(raw: unknown): string {
  const value = withRosterReason(REASON.INVALID_TEAM_ID, () => boundedTrimmedString(raw, "teamId", 64, true));
  if (!TEAM_ID_PATTERN.test(value)) {
    throw rosterError(REASON.INVALID_TEAM_ID, "teamId is not a valid team identifier.");
  }
  return value;
}

function requireUid(raw: unknown, fieldName: string): string {
  const value = withRosterReason(REASON.INVALID_ACCOUNT_ID, () => boundedTrimmedString(raw, fieldName, 128, true));
  if (!/^[A-Za-z0-9_-]{1,128}$/u.test(value)) {
    throw rosterError(REASON.INVALID_ACCOUNT_ID, `${fieldName} is not a valid account identifier.`);
  }
  return value;
}

function requireRole(raw: unknown): "admin" | "member" {
  const value = withRosterReason(REASON.INVALID_ROLE, () => boundedTrimmedString(raw, "role", 16, false)) ?? "member";
  if (value !== "admin" && value !== "member") {
    throw rosterError(REASON.INVALID_ROLE, 'role must be "admin" or "member".');
  }
  return value;
}

function requireInviteeEmail(raw: unknown): string {
  const value = withRosterReason(REASON.INVALID_INVITEE_EMAIL, () =>
    boundedTrimmedString(raw, "inviteeEmail", 320, true),
  ).toLowerCase();
  if (!/^[^\s@]+@[^\s@.]+\.[^\s@]+$/u.test(value)) {
    throw rosterError(REASON.INVALID_INVITEE_EMAIL, "inviteeEmail must be a valid email address.");
  }
  return value;
}

function requireEnvelopeIds(raw: unknown): Set<string> {
  const values = withRosterReason(REASON.INVALID_ENVELOPE_IDS, () =>
    requireBoundedStringArray(raw, "envelopeIds", MAX_ENVELOPE_IDS, 320),
  );
  for (const value of values) {
    if (!/^[A-Za-z0-9_.:-]+$/u.test(value)) {
      throw rosterError(REASON.INVALID_ENVELOPE_ID, "envelopeIds contains an unsupported document id.");
    }
  }
  return new Set(values);
}

const TEAM_CALLABLE_OPTIONS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 20,
};

export const createTeam = onCallProduction(
  "createTeam",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ name?: unknown }>) => {
    const uid = requireAuthUid(request);
    const name = withRosterReason(REASON.INVALID_TEAM_NAME, () =>
      boundedTrimmedString(request.data?.name, "name", 100, true),
    );
    await checkTeamRosterMutationRateLimit(uid);
    return TeamRosterService.createTeam(uid, name);
  },
);

export const inviteTeamMember = onCallProduction(
  "inviteTeamMember",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; inviteeEmail?: unknown; role?: unknown }>) => {
    const uid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const inviteeEmail = requireInviteeEmail(request.data?.inviteeEmail);
    const role = requireRole(request.data?.role);
    // Bound before the directory lookup: `getUserByEmail` is an account-
    // existence oracle, so the invite path is rate limited per admin uid.
    await checkTeamInviteRateLimit(uid);
    return TeamRosterService.inviteMember(uid, teamId, inviteeEmail, role);
  },
);

export const acceptTeamInvite = onCallProduction(
  "acceptTeamInvite",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; inviteToken?: unknown }>) => {
    const uid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const inviteToken = withRosterReason(REASON.INVALID_INVITE_TOKEN, () =>
      boundedTrimmedString(request.data?.inviteToken, "inviteToken", 128, true),
    );
    if (!INVITE_TOKEN_PATTERN.test(inviteToken)) {
      throw rosterError(REASON.INVALID_INVITE_TOKEN, "inviteToken is not a valid invite token.");
    }
    // Bound before the hash lookup so a stolen-but-unbound token cannot be
    // brute forced against the invite namespace.
    await checkTeamInviteAcceptRateLimit(uid);
    return TeamRosterService.acceptInvite(uid, request.auth?.token?.email_verified === true, teamId, inviteToken);
  },
);

export const promoteTeamMember = onCallProduction(
  "promoteTeamMember",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; uid?: unknown; envelopeIds?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const targetUid = requireUid(request.data?.uid, "uid");
    const envelopeIds = requireEnvelopeIds(request.data?.envelopeIds);
    await checkTeamRosterMutationRateLimit(callerUid);
    return TeamRosterService.promoteMember(callerUid, teamId, targetUid, envelopeIds);
  },
);

export const removeTeamMember = onCallProduction(
  "removeTeamMember",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; targetUid?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const targetUid = requireUid(request.data?.targetUid, "targetUid");
    await checkTeamRosterMutationRateLimit(callerUid);
    return TeamRosterService.removeMember(callerUid, teamId, targetUid);
  },
);

export const recordTeamRewrapComplete = onCallProduction(
  "recordTeamRewrapComplete",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; keyVersion?: unknown; rewrapJobId?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const keyVersion = withRosterReason(REASON.INVALID_KEY_VERSION, () =>
      requireBoundedNumber(request.data?.keyVersion, "keyVersion", 1, MAX_TEAM_KEY_VERSION),
    );
    const rewrapJobId = withRosterReason(REASON.INVALID_REWRAP_JOB_ID, () =>
      boundedTrimmedString(request.data?.rewrapJobId, "rewrapJobId", MAX_REWRAP_JOB_ID_LENGTH, true),
    );
    // A correlation handle, not a secret and not an id the server resolves —
    // bounded to the shape a UUID or a short slug takes so it cannot be used to
    // smuggle bytes into a document every member reads.
    if (!/^[A-Za-z0-9_.:-]+$/u.test(rewrapJobId)) {
      throw rosterError(REASON.INVALID_REWRAP_JOB_ID, "rewrapJobId is not a valid job identifier.");
    }
    await checkTeamRosterMutationRateLimit(callerUid);
    return TeamRosterService.recordRewrapComplete(callerUid, teamId, keyVersion, rewrapJobId);
  },
);

export const rotateTeamKey = onCallProduction(
  "rotateTeamKey",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; newKeyVersion?: unknown; envelopeIds?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const newKeyVersion = withRosterReason(REASON.INVALID_KEY_VERSION, () =>
      requireBoundedNumber(request.data?.newKeyVersion, "newKeyVersion", 2, MAX_TEAM_KEY_VERSION),
    );
    const envelopeIds = requireEnvelopeIds(request.data?.envelopeIds);
    await checkTeamRosterMutationRateLimit(callerUid);
    return TeamRosterService.rotateTeamKey(callerUid, teamId, newKeyVersion, envelopeIds);
  },
);

/**
 * Burn a key generation an abandoned rotation left occupying its envelope ids,
 * so the team can rotate past it. Admin-only, and the service refuses any
 * version that is not the next unclaimed one, is recorded as active or
 * retained, or has no published envelope — see `TeamRosterService.abandonKeyGeneration`.
 */
export const abandonTeamKeyGeneration = onCallProduction(
  "abandonTeamKeyGeneration",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; version?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const version = withRosterReason(REASON.INVALID_KEY_VERSION, () =>
      requireBoundedNumber(request.data?.version, "version", 2, MAX_TEAM_KEY_VERSION),
    );
    await checkTeamRosterMutationRateLimit(callerUid);
    return TeamRosterService.abandonKeyGeneration(callerUid, teamId, version);
  },
);

/**
 * Record the founding `teamSlugKey`'s fingerprint, so joiners' slug envelopes
 * land in the ACTIVE key ring instead of the pending one (design §3(b)1, B6).
 *
 * A DIGEST, NOT A KEY, and the validator is what makes that structural: the
 * pattern admits exactly `CloudVaultCrypto.vaultKeyID`'s output and nothing
 * else, so no key material — and no arbitrary bytes — can be smuggled into a
 * document every member of the team reads.
 */
export const recordTeamSlugKeyId = onCallProduction(
  "recordTeamSlugKeyId",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; slugKeyId?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const slugKeyId = withRosterReason(REASON.INVALID_SLUG_KEY_ID, () =>
      boundedTrimmedString(request.data?.slugKeyId, "slugKeyId", 64, true),
    );
    if (!SLUG_KEY_ID_PATTERN.test(slugKeyId)) {
      throw rosterError(REASON.INVALID_SLUG_KEY_ID, "slugKeyId is not a valid key fingerprint.");
    }
    await checkTeamRosterMutationRateLimit(callerUid);
    return recordSlugKeyId(callerUid, teamId, slugKeyId);
  },
);
