/**
 * @fileoverview Callable surface for the team roster authority (D16 / P21).
 *
 * Every payload is validated here and nothing else reaches
 * {@link TeamRosterService}: a team id must match the shape the memory engine
 * parses, an invite token must look like one before it is hashed and looked
 * up, and no callable anywhere on this surface accepts a client-supplied
 * escrow public key.
 */

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  INVITE_TOKEN_PATTERN,
  MAX_ENVELOPE_IDS,
  MAX_TEAM_KEY_VERSION,
  TEAM_ID_PATTERN,
  TeamRosterService,
} from "../teamRoster.js";
import { boundedTrimmedString, requireBoundedNumber, requireBoundedStringArray } from "./shared/validators.js";
import {
  checkTeamInviteAcceptRateLimit,
  checkTeamInviteRateLimit,
  checkTeamRosterMutationRateLimit,
} from "./publicRateLimit.js";

function requireAuthUid(request: CallableRequest<unknown>): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in before managing a team.");
  }
  return uid;
}

function requireTeamId(raw: unknown): string {
  const value = boundedTrimmedString(raw, "teamId", 64, true);
  if (!TEAM_ID_PATTERN.test(value)) {
    throw new HttpsError("invalid-argument", "teamId is not a valid team identifier.");
  }
  return value;
}

function requireUid(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 128, true);
  if (!/^[A-Za-z0-9_-]{1,128}$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} is not a valid account identifier.`);
  }
  return value;
}

function requireRole(raw: unknown): "admin" | "member" {
  const value = boundedTrimmedString(raw, "role", 16, false) ?? "member";
  if (value !== "admin" && value !== "member") {
    throw new HttpsError("invalid-argument", 'role must be "admin" or "member".');
  }
  return value;
}

function requireInviteeEmail(raw: unknown): string {
  const value = boundedTrimmedString(raw, "inviteeEmail", 320, true).toLowerCase();
  if (!/^[^\s@]+@[^\s@.]+\.[^\s@]+$/u.test(value)) {
    throw new HttpsError("invalid-argument", "inviteeEmail must be a valid email address.");
  }
  return value;
}

function requireEnvelopeIds(raw: unknown): Set<string> {
  const values = requireBoundedStringArray(raw, "envelopeIds", MAX_ENVELOPE_IDS, 320);
  for (const value of values) {
    if (!/^[A-Za-z0-9_.:-]+$/u.test(value)) {
      throw new HttpsError("invalid-argument", "envelopeIds contains an unsupported document id.");
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
    const name = boundedTrimmedString(request.data?.name, "name", 100, true);
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
    const inviteToken = boundedTrimmedString(request.data?.inviteToken, "inviteToken", 128, true);
    if (!INVITE_TOKEN_PATTERN.test(inviteToken)) {
      throw new HttpsError("invalid-argument", "inviteToken is not a valid invite token.");
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

export const rotateTeamKey = onCallProduction(
  "rotateTeamKey",
  TEAM_CALLABLE_OPTIONS,
  async (request: CallableRequest<{ teamId?: unknown; newKeyVersion?: unknown; envelopeIds?: unknown }>) => {
    const callerUid = requireAuthUid(request);
    const teamId = requireTeamId(request.data?.teamId);
    const newKeyVersion = requireBoundedNumber(request.data?.newKeyVersion, "newKeyVersion", 2, MAX_TEAM_KEY_VERSION);
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
    const version = requireBoundedNumber(request.data?.version, "version", 2, MAX_TEAM_KEY_VERSION);
    await checkTeamRosterMutationRateLimit(callerUid);
    return TeamRosterService.abandonKeyGeneration(callerUid, teamId, version);
  },
);
