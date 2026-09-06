/**
 * @fileoverview Team key envelopes: the ECIES wrap lane for team memory (D16 / P21).
 *
 * A team vault key never reaches the server. It is wrapped client-side, once
 * per RECIPIENT DEVICE (a member's second Mac holds a different escrow private
 * key), and published to `team_key_envelopes/{teamId}/envelopes/{envelopeId}`
 * where `firestore.rules` allows only an active admin — or a member wrapping
 * for their own uid — to create it, and nobody to update or delete it.
 *
 * This module owns the two questions the roster authority asks about that lane:
 * WHICH envelopes a member must hold before it is key-covered, and WHETHER the
 * published documents actually satisfy that requirement.
 *
 * No function here accepts key material or a recipient public key from a
 * client. Fingerprints come from the member row, which `TeamRosterService`
 * pinned from the member's own `users/{uid}/escrow_public_keys` namespace.
 */

import { db } from "./adminRuntime.js";
import { TEAM_ROSTER_REASON as REASON, rosterError } from "./teamRosterReasons.js";

/**
 * Envelope coverage is verified with one existence read per required envelope,
 * so both ends are bounded: a member pins at most this many devices, and a
 * single promote/rotate may name at most {@link MAX_ENVELOPE_IDS} envelopes.
 * A rotation covering more (member, device) pairs than that is refused rather
 * than fanning out an unbounded read amplification from one callable.
 */
export const MAX_TEAM_MEMBER_DEVICES = 20;
export const MAX_ENVELOPE_IDS = 5000;

/**
 * Pinned at accept time from the joiner's own escrow namespace — fingerprints
 * only, never key bytes.
 *
 * Module-private: this is a server-internal shape, not a client schema mirror,
 * so it is not part of the hand-maintained schema surface. `teamRoster.ts`
 * derives it from `readEscrowDeviceFingerprints` rather than importing a name.
 */
interface TeamEscrowDeviceFingerprint {
  deviceId: string;
  keyVersion: number;
  publicKeyFingerprint: string;
}

/**
 * `firestore.rules` requires `d.escrowKeyVersion is int && >= 1` on every
 * envelope, so an escrow key published with a `keyVersion` outside that range
 * names an envelope that can never be written (PR1 review N-5). Such a device
 * is refused at pin time rather than pinned into an unfulfillable requirement.
 */
export function isPinnableEscrowKeyVersion(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1;
}

/**
 * The exact shape of an escrow device's `publicKeyFingerprint`: base64 of a
 * 32-byte SHA-256 digest over the x9.63 public key, i.e. 43 base64 characters
 * plus the single `=` pad.
 *
 * NOT hex (memory program D16 / PR 2 defect fix). Every producer and consumer
 * of this value speaks base64 — `CloudVaultDeviceKeypair.publicKeyFingerprint`
 * writes the base64 of the SHA-256 over the device's raw public key bytes,
 * `users/{uid}/escrow_public_keys` stores it verbatim, and
 * `EscrowDeviceSafetyCode.isFingerprint` base64-DECODES it to re-derive the
 * binding against the real key bytes. PR 1 filtered pins with `^[a-f0-9]{64}$`,
 * which matches no fingerprint any device has ever published, so
 * `pinEscrowDeviceFingerprints` dropped every device and every join was refused
 * with "publish and trust at least one device". `firestore.rules` pins the same
 * shape on an envelope's `recipientPublicKeyFingerprint`, so the two ends agree.
 */
export function isEscrowPublicKeyFingerprint(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9+/]{43}=$/u.test(value);
}

export function readEscrowDeviceFingerprints(raw: unknown): TeamEscrowDeviceFingerprint[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item) => {
    if (item === null || typeof item !== "object" || Array.isArray(item)) return [];
    const deviceId = Reflect.get(item, "deviceId");
    const keyVersion = Reflect.get(item, "keyVersion");
    const publicKeyFingerprint = Reflect.get(item, "publicKeyFingerprint");
    if (typeof deviceId !== "string" || !isPinnableEscrowKeyVersion(keyVersion)) return [];
    if (typeof publicKeyFingerprint !== "string") return [];
    return [{ deviceId, keyVersion, publicKeyFingerprint }];
  });
}

/**
 * Envelope document id for one (member device, key) pair. `keyVersion` is the
 * team vault key version; the non-rotating slug key uses the `slug` slot, so a
 * joiner is only promoted once it can both DECRYPT (vault key) and NAME (slug
 * key) team documents.
 */
function teamKeyEnvelopeId(uid: string, device: TeamEscrowDeviceFingerprint, keyVersion: number | "slug"): string {
  const slot = keyVersion === "slug" ? "slug" : `v${keyVersion}`;
  return `${uid}_${device.deviceId}_${device.keyVersion}_${slot}`;
}

/**
 * One envelope a member must hold before it is key-covered: the document id
 * plus every field that id is required to name, INCLUDING the escrow public key
 * fingerprint pinned on the member row at accept time. The fingerprint is what
 * makes coverage a control rather than bookkeeping — see
 * {@link assertTeamKeyEnvelopeCoverage}.
 */
interface TeamKeyEnvelopeRequirement {
  id: string;
  uid: string;
  deviceId: string;
  escrowKeyVersion: number;
  keySlot: string;
  publicKeyFingerprint: string;
}

/**
 * The envelopes a member needs before it can be flipped to `active`, or before
 * a rotation may be recorded. `includeSlugKey` is true only on join: a rotation
 * never re-issues the non-rotating slug key.
 */
export function requiredTeamKeyEnvelopes(options: {
  uid: string;
  devices: TeamEscrowDeviceFingerprint[];
  keyVersions: number[];
  includeSlugKey: boolean;
}): TeamKeyEnvelopeRequirement[] {
  const { uid, devices, keyVersions, includeSlugKey } = options;
  const requirements: TeamKeyEnvelopeRequirement[] = [];
  const slots: Array<number | "slug"> = includeSlugKey ? [...keyVersions, "slug"] : [...keyVersions];
  for (const device of devices) {
    for (const slot of slots) {
      requirements.push({
        id: teamKeyEnvelopeId(uid, device, slot),
        uid,
        deviceId: device.deviceId,
        escrowKeyVersion: device.keyVersion,
        keySlot: slot === "slug" ? "slug" : `v${slot}`,
        publicKeyFingerprint: device.publicKeyFingerprint,
      });
    }
  }
  return requirements;
}

/** Ids only — the shape callers compare against a client's `envelopeIds` claim. */
export function requiredTeamKeyEnvelopeIds(options: {
  uid: string;
  devices: TeamEscrowDeviceFingerprint[];
  keyVersions: number[];
  includeSlugKey: boolean;
}): string[] {
  return requiredTeamKeyEnvelopes(options).map((requirement) => requirement.id);
}

/**
 * Verify every required envelope is claimed by the caller, actually present,
 * and BOUND to the recipient's pinned escrow key.
 *
 * The binding is the point (PR1 review F2). `pinEscrowDeviceFingerprints`
 * reads the joiner's own `users/{uid}/escrow_public_keys` precisely so that a
 * client-supplied recipient key cannot be substituted — but a fingerprint
 * nobody reads back is bookkeeping, not a control. So each envelope must name
 * the exact `(deviceId, escrowKeyVersion, keySlot)` its id encodes AND carry
 * the `recipientPublicKeyFingerprint` pinned on the member row for that
 * device. An envelope wrapped to some other key satisfies nothing: the
 * requirement it was meant to cover is simply unmet, and the promotion or
 * rotation is refused.
 *
 * `wrappedBy` (pinned to the author by `firestore.rules`) must be an admin of
 * this team or the recipient themselves — a plain member's wrap for a third
 * party never counts toward coverage even if the rules let it be written.
 *
 * AN ADMIN IN ANY STATUS COUNTS, not only a currently active one (PR1 review
 * N-2). The rules already decide, at CREATE time, that the writer was an
 * active admin or the recipient; that write-time decision is the authority,
 * and re-litigating it at read time buys nothing while costing availability.
 * Envelopes are create-only and immutable, so if the admin who wrapped a
 * pending joiner's envelopes leaves before the joiner is promoted, a
 * "currently active" test would strand that joiner permanently: the wraps are
 * perfectly decryptable, but no surviving admin can repair them because
 * `create` is denied on documents that already exist. A departed admin's
 * pre-departure wraps therefore stay valid, and ROTATION — not coverage
 * arithmetic — is what revokes their access to the key they wrapped.
 */
export async function assertTeamKeyEnvelopeCoverage(
  teamId: string,
  requirements: TeamKeyEnvelopeRequirement[],
  claimedIds: Set<string>,
  authorizedWrapperUids: Set<string>,
): Promise<void> {
  if (requirements.length > MAX_ENVELOPE_IDS) {
    throw rosterError(
      REASON.TOO_MANY_KEY_ENVELOPES,
      `This team needs ${requirements.length} key envelopes, above the ${MAX_ENVELOPE_IDS} a single call may verify.`,
    );
  }
  const missing = requirements.filter((requirement) => !claimedIds.has(requirement.id));
  if (missing.length > 0) {
    throw rosterError(
      REASON.KEY_ENVELOPE_COVERAGE_INCOMPLETE,
      `Key envelope coverage is incomplete: ${missing.length} envelope(s) were not supplied.`,
    );
  }
  const snapshots = await Promise.all(
    requirements.map((requirement) => db.doc(`team_key_envelopes/${teamId}/envelopes/${requirement.id}`).get()),
  );
  snapshots.forEach((snapshot, index) => {
    const requirement = requirements[index];
    if (!requirement) return;
    if (!snapshot.exists) {
      throw rosterError(
        REASON.KEY_ENVELOPE_NOT_PUBLISHED,
        `Key envelope ${requirement.id} has not been published yet.`,
      );
    }
    if (
      snapshot.get("teamId") !== teamId ||
      snapshot.get("uid") !== requirement.uid ||
      snapshot.get("deviceId") !== requirement.deviceId ||
      snapshot.get("escrowKeyVersion") !== requirement.escrowKeyVersion ||
      snapshot.get("keySlot") !== requirement.keySlot
    ) {
      throw rosterError(
        REASON.KEY_ENVELOPE_ADDRESSED_ELSEWHERE,
        `Key envelope ${requirement.id} is not addressed to the expected member device.`,
      );
    }
    if (snapshot.get("recipientPublicKeyFingerprint") !== requirement.publicKeyFingerprint) {
      throw rosterError(
        REASON.KEY_ENVELOPE_WRAPPED_TO_UNKNOWN_KEY,
        `Key envelope ${requirement.id} is wrapped to a key this member never published.`,
      );
    }
    const wrappedBy = snapshot.get("wrappedBy");
    if (typeof wrappedBy !== "string" || !(authorizedWrapperUids.has(wrappedBy) || wrappedBy === requirement.uid)) {
      throw rosterError(
        REASON.KEY_ENVELOPE_WRAPPER_NOT_AUTHORIZED,
        `Key envelope ${requirement.id} was not published by a team admin or by its recipient.`,
      );
    }
  });
}
