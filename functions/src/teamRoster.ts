/**
 * @fileoverview Team Roster Service & Roster Authority (D16 / P21).
 *
 * Implements the server-side roster writer for BurnBar Team Memory.
 * Firestore security rules strictly prohibit client SDK writes to `team_rosters`
 * and `team_key_envelopes`. All mutations to team rosters, membership lifecycles,
 * and key envelope distribution flow through this authenticated authority.
 */

import { randomUUID } from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "./adminRuntime.js";
import { onCallProduction } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

export interface TeamDocument {
  teamId: string;
  orgId?: string | null;
  name: string;
  activeKeyVersion: number;
  keyRotationRequired: boolean;
  createdAt: Timestamp | FieldValue;
  updatedAt: Timestamp | FieldValue;
}

export interface TeamMemberDocument {
  uid: string;
  teamId: string;
  role: "admin" | "member";
  status: "active" | "suspended" | "removed";
  escrowPublicKey?: string;
  escrowKeyVersion?: number;
  activeTeamKeyVersion: number;
  joinedAt: Timestamp | FieldValue;
  invitedBy: string;
  updatedAt: Timestamp | FieldValue;
  removedAt?: Timestamp | FieldValue;
}

export interface TeamInviteDocument {
  token: string;
  teamId: string;
  email: string;
  role: "admin" | "member";
  status: "pending" | "accepted" | "revoked" | "expired";
  invitedBy: string;
  createdAt: Timestamp | FieldValue;
  expiresAt: Timestamp;
}

export class TeamRosterService {
  /**
   * Create a new team roster with caller as the founding admin.
   */
  static async createTeam(
    callerUid: string,
    name: string,
    orgId?: string | null,
  ): Promise<{ teamId: string; role: "admin"; activeKeyVersion: number }> {
    const trimmedName = name.trim();
    if (!trimmedName || trimmedName.length > 100) {
      throw new HttpsError("invalid-argument", "Team name must be between 1 and 100 characters.");
    }

    const teamId = `team_${randomUUID().replace(/-/g, "").slice(0, 16)}`;
    const now = FieldValue.serverTimestamp();

    const teamRef = db.doc(`team_rosters/${teamId}`);
    const memberRef = db.doc(`team_rosters/${teamId}/members/${callerUid}`);

    const batch = db.batch();
    batch.set(teamRef, {
      teamId,
      orgId: orgId ?? null,
      name: trimmedName,
      activeKeyVersion: 1,
      keyRotationRequired: false,
      createdAt: now,
      updatedAt: now,
    } satisfies TeamDocument);

    batch.set(memberRef, {
      uid: callerUid,
      teamId,
      role: "admin",
      status: "active",
      activeTeamKeyVersion: 1,
      joinedAt: now,
      invitedBy: callerUid,
      updatedAt: now,
    } satisfies TeamMemberDocument);

    await batch.commit();
    return { teamId, role: "admin", activeKeyVersion: 1 };
  }

  /**
   * Invite a new member to the team. Requires caller to be an active admin.
   */
  static async inviteMember(
    callerUid: string,
    teamId: string,
    email: string,
    role: "admin" | "member" = "member",
  ): Promise<{ inviteToken: string; teamId: string }> {
    await this.assertActiveAdmin(callerUid, teamId);

    const normalizedEmail = email.trim().toLowerCase();
    if (!normalizedEmail || !normalizedEmail.includes("@")) {
      throw new HttpsError("invalid-argument", "Valid email address required.");
    }

    const inviteToken = `inv_${randomUUID().replace(/-/g, "")}`;
    const now = FieldValue.serverTimestamp();
    const expiresAt = Timestamp.fromMillis(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days

    const inviteRef = db.doc(`team_rosters/${teamId}/invites/${inviteToken}`);
    await inviteRef.set({
      token: inviteToken,
      teamId,
      email: normalizedEmail,
      role,
      status: "pending",
      invitedBy: callerUid,
      createdAt: now,
      expiresAt,
    } satisfies TeamInviteDocument);

    return { inviteToken, teamId };
  }

  /**
   * Accept an invite and register member's escrow public key.
   */
  static async acceptInvite(
    callerUid: string,
    teamId: string,
    inviteToken: string,
    escrowPublicKey: string,
    escrowKeyVersion = 1,
  ): Promise<{ success: boolean; teamId: string; role: "admin" | "member" }> {
    if (!escrowPublicKey || escrowPublicKey.length > 512) {
      throw new HttpsError("invalid-argument", "Valid escrow public key required.");
    }

    const inviteRef = db.doc(`team_rosters/${teamId}/invites/${inviteToken}`);
    const inviteSnap = await inviteRef.get();
    if (!inviteSnap.exists) {
      throw new HttpsError("not-found", "Invite not found or expired.");
    }

    const invite = inviteSnap.data() as TeamInviteDocument;
    if (invite.status !== "pending") {
      throw new HttpsError("failed-precondition", `Invite is already ${invite.status}.`);
    }

    if (invite.expiresAt.toMillis() < Date.now()) {
      await inviteRef.update({ status: "expired" });
      throw new HttpsError("failed-precondition", "Invite has expired.");
    }

    const teamSnap = await db.doc(`team_rosters/${teamId}`).get();
    if (!teamSnap.exists) {
      throw new HttpsError("not-found", "Team not found.");
    }
    const team = teamSnap.data() as TeamDocument;

    const memberRef = db.doc(`team_rosters/${teamId}/members/${callerUid}`);
    const now = FieldValue.serverTimestamp();

    const batch = db.batch();
    batch.update(inviteRef, { status: "accepted", updatedAt: now });
    batch.set(memberRef, {
      uid: callerUid,
      teamId,
      role: invite.role,
      status: "active",
      escrowPublicKey,
      escrowKeyVersion,
      activeTeamKeyVersion: team.activeKeyVersion,
      joinedAt: now,
      invitedBy: invite.invitedBy,
      updatedAt: now,
    } satisfies TeamMemberDocument);

    await batch.commit();
    return { success: true, teamId, role: invite.role };
  }

  /**
   * Remove a member from the team.
   * Setting status to "removed" triggers an immediate Firestore rules cutoff.
   */
  static async removeMember(
    callerUid: string,
    teamId: string,
    targetUid: string,
  ): Promise<{ success: boolean; teamId: string; targetUid: string; keyRotationRequired: boolean }> {
    // Caller must be an admin, or member removing themselves
    if (callerUid !== targetUid) {
      await this.assertActiveAdmin(callerUid, teamId);
    }

    const memberRef = db.doc(`team_rosters/${teamId}/members/${targetUid}`);
    const memberSnap = await memberRef.get();
    if (!memberSnap.exists) {
      throw new HttpsError("not-found", "Member not found in team.");
    }

    const now = FieldValue.serverTimestamp();
    const batch = db.batch();

    batch.update(memberRef, {
      status: "removed",
      removedAt: now,
      updatedAt: now,
    });

    batch.update(db.doc(`team_rosters/${teamId}`), {
      keyRotationRequired: true,
      updatedAt: now,
    });

    await batch.commit();
    return { success: true, teamId, targetUid, keyRotationRequired: true };
  }

  /**
   * Rotate team vault key and store re-wrapped envelopes for remaining active members.
   */
  static async rotateTeamKey(
    callerUid: string,
    teamId: string,
    newKeyVersion: number,
    envelopes: Record<string, string>,
  ): Promise<{ success: boolean; teamId: string; activeKeyVersion: number }> {
    await this.assertActiveAdmin(callerUid, teamId);

    const teamRef = db.doc(`team_rosters/${teamId}`);
    const teamSnap = await teamRef.get();
    if (!teamSnap.exists) {
      throw new HttpsError("not-found", "Team not found.");
    }

    const team = teamSnap.data() as TeamDocument;
    if (newKeyVersion !== team.activeKeyVersion + 1) {
      throw new HttpsError(
        "invalid-argument",
        `Expected newKeyVersion to be ${team.activeKeyVersion + 1}, got ${newKeyVersion}.`,
      );
    }

    // Verify each envelope corresponds to an active member
    const activeMembersSnap = await db
      .collection(`team_rosters/${teamId}/members`)
      .where("status", "==", "active")
      .get();

    const activeUids = new Set(activeMembersSnap.docs.map((d) => d.id));
    const batch = db.batch();
    const now = FieldValue.serverTimestamp();

    for (const [targetUid, envelopeCiphertextBase64] of Object.entries(envelopes)) {
      if (!activeUids.has(targetUid)) {
        throw new HttpsError("invalid-argument", `Cannot write key envelope for non-active member ${targetUid}.`);
      }

      const envRef = db.doc(`team_key_envelopes/${teamId}/envelopes/${targetUid}_v${newKeyVersion}`);
      batch.set(envRef, {
        teamId,
        uid: targetUid,
        keyVersion: newKeyVersion,
        envelopeCiphertext: envelopeCiphertextBase64,
        createdAt: now,
      });
    }

    batch.update(teamRef, {
      activeKeyVersion: newKeyVersion,
      keyRotationRequired: false,
      updatedAt: now,
    });

    await batch.commit();
    return { success: true, teamId, activeKeyVersion: newKeyVersion };
  }

  private static async assertActiveAdmin(callerUid: string, teamId: string): Promise<void> {
    const memberSnap = await db.doc(`team_rosters/${teamId}/members/${callerUid}`).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "Caller is not a member of this team.");
    }

    const member = memberSnap.data() as TeamMemberDocument;
    if (member.status !== "active" || member.role !== "admin") {
      throw new HttpsError("permission-denied", "Caller must be an active team admin.");
    }
  }
}

// --- Firebase Callables ---

export const createTeam = onCallProduction(
  "createTeam",
  { region: FUNCTIONS_REGION },
  async (request: CallableRequest<{ name: string; orgId?: string | null }>) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    return TeamRosterService.createTeam(request.auth.uid, request.data.name, request.data.orgId);
  },
);

export const inviteTeamMember = onCallProduction(
  "inviteTeamMember",
  { region: FUNCTIONS_REGION },
  async (
    request: CallableRequest<{
      teamId: string;
      email: string;
      role?: "admin" | "member";
    }>,
  ) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    return TeamRosterService.inviteMember(request.auth.uid, request.data.teamId, request.data.email, request.data.role);
  },
);

export const acceptTeamInvite = onCallProduction(
  "acceptTeamInvite",
  { region: FUNCTIONS_REGION },
  async (
    request: CallableRequest<{
      teamId: string;
      inviteToken: string;
      escrowPublicKey: string;
      escrowKeyVersion?: number;
    }>,
  ) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    return TeamRosterService.acceptInvite(
      request.auth.uid,
      request.data.teamId,
      request.data.inviteToken,
      request.data.escrowPublicKey,
      request.data.escrowKeyVersion,
    );
  },
);

export const removeTeamMember = onCallProduction(
  "removeTeamMember",
  { region: FUNCTIONS_REGION },
  async (request: CallableRequest<{ teamId: string; targetUid: string }>) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    return TeamRosterService.removeMember(request.auth.uid, request.data.teamId, request.data.targetUid);
  },
);

export const rotateTeamKey = onCallProduction(
  "rotateTeamKey",
  { region: FUNCTIONS_REGION },
  async (
    request: CallableRequest<{
      teamId: string;
      newKeyVersion: number;
      envelopes: Record<string, string>;
    }>,
  ) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    return TeamRosterService.rotateTeamKey(
      request.auth.uid,
      request.data.teamId,
      request.data.newKeyVersion,
      request.data.envelopes,
    );
  },
);
