/**
 * @fileoverview Read-only scanner for legacy plaintext shared artifacts.
 *
 * The server cannot re-seal content because CloudVault keys never leave trusted
 * devices. This callable returns only document identifiers and metadata flags,
 * allowing clients to pull matching artifacts through the normal local
 * decrypt/re-seal path.
 */

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { FieldPath, getFirestore } from "firebase-admin/firestore";

import { getConfig } from "../config.js";
import { onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { boundedInteger } from "./computerUseSecurityCodecs.js";

interface LegacyPlaintextArtifactHit {
  readonly artifactPath: string;
  readonly artifactID: string;
  readonly workspaceID: string;
  readonly teamID: string;
  readonly revisionID: string | null;
  readonly hasTitle: boolean;
  readonly hasBody: boolean;
  readonly hasContentHash: boolean;
}

interface LegacyPlaintextScanResult {
  readonly scannedDocuments: number;
  readonly legacyPlaintextCount: number;
  readonly hits: readonly LegacyPlaintextArtifactHit[];
  readonly truncated: boolean;
  readonly nextPageToken: string | null;
  readonly scannedAt: string;
}

type LegacyScanQuerySnapshot<TDoc> = {
  readonly docs: readonly TDoc[];
};

type LegacyScanQuery<TDoc> = {
  orderBy(fieldPath: unknown): LegacyScanQuery<TDoc>;
  startAfter(...fieldValues: unknown[]): LegacyScanQuery<TDoc>;
  startAt(...fieldValues: unknown[]): LegacyScanQuery<TDoc>;
  limit(count: number): LegacyScanQuery<TDoc>;
  get(): Promise<LegacyScanQuerySnapshot<TDoc>>;
};

type LegacyScanCollection<TDoc> = LegacyScanQuery<TDoc>;

type LegacyScanArtifactDoc = {
  readonly id: string;
  readonly ref: { readonly path: string };
  data(): Record<string, unknown>;
};

type LegacyScanTeamDoc = {
  readonly id: string;
  readonly ref: {
    collection(name: "artifacts"): LegacyScanCollection<LegacyScanArtifactDoc>;
  };
};

export type LegacyScanDb = {
  collection(path: string): LegacyScanCollection<LegacyScanTeamDoc>;
};

const DEFAULT_SCAN_LIMIT = 500;
const MAX_SCAN_LIMIT = 5_000;
const DEFAULT_RESULT_LIMIT = 200;
const MAX_RESULT_LIMIT = 1_000;
const MAX_TEAMS_PER_SCAN = 100;
const MAX_PAGE_TOKEN_BYTES = 1_024;
const DOCUMENT_ID = FieldPath.documentId();

type LegacyPlaintextScanCursor = {
  readonly teamID: string;
  readonly artifactID: string | null;
};

export function isLegacyPlaintextArtifactData(data: Record<string, unknown>): boolean {
  return (
    typeof data["title"] === "string" || typeof data["body"] === "string" || typeof data["contentHash"] === "string"
  );
}

function encodePageToken(cursor: LegacyPlaintextScanCursor | null): string | null {
  if (!cursor) return null;
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

function decodePageToken(raw: unknown): LegacyPlaintextScanCursor | null {
  if (raw == null) return null;
  if (typeof raw !== "string") {
    throw new HttpsError("invalid-argument", "pageToken must be a string.");
  }
  if (raw.trim() === "") return null;
  if (Buffer.byteLength(raw, "utf8") > MAX_PAGE_TOKEN_BYTES) {
    throw new HttpsError("invalid-argument", "pageToken is too large.");
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(Buffer.from(raw, "base64url").toString("utf8"));
  } catch {
    throw new HttpsError("invalid-argument", "pageToken is invalid.");
  }

  if (!decoded || typeof decoded !== "object") {
    throw new HttpsError("invalid-argument", "pageToken is invalid.");
  }
  const rawTeamID = Reflect.get(decoded, "teamID");
  const rawArtifactID = Reflect.get(decoded, "artifactID");
  const teamID = validateCursorID(rawTeamID, "teamID");
  const artifactID = rawArtifactID == null ? null : validateCursorID(rawArtifactID, "artifactID");
  return { teamID, artifactID };
}

function validateCursorID(value: unknown, field: string): string {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `pageToken ${field} must be a string.`);
  }
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.includes("/")) {
    throw new HttpsError("invalid-argument", `pageToken ${field} is invalid.`);
  }
  return trimmed;
}

export async function scanLegacyPlaintextArtifactsForUser(
  db: LegacyScanDb,
  uid: string,
  scanLimit: number,
  resultLimit: number,
  pageToken: unknown = null,
  now: Date = new Date(),
): Promise<LegacyPlaintextScanResult> {
  const workspaceID = `workspace-${uid}`;
  const hits: LegacyPlaintextArtifactHit[] = [];
  let scannedDocuments = 0;
  let truncated = false;
  let nextCursor: LegacyPlaintextScanCursor | null = null;
  const pageCursor = decodePageToken(pageToken);

  let teamsQuery = db.collection(`workspaces/${workspaceID}/teams`).orderBy(DOCUMENT_ID);
  if (pageCursor) {
    teamsQuery = pageCursor.artifactID
      ? teamsQuery.startAt(pageCursor.teamID)
      : teamsQuery.startAfter(pageCursor.teamID);
  }
  const teamsSnapshot = await teamsQuery.limit(MAX_TEAMS_PER_SCAN + 1).get();
  const teamDocs = teamsSnapshot.docs.slice(0, MAX_TEAMS_PER_SCAN);
  const hasMoreTeams = teamsSnapshot.docs.length > MAX_TEAMS_PER_SCAN;

  for (const [teamIndex, teamDoc] of teamDocs.entries()) {
    if (hits.length >= resultLimit || scannedDocuments >= scanLimit) {
      truncated = true;
      nextCursor = { teamID: teamDoc.id, artifactID: null };
      break;
    }

    const remainingScanBudget = scanLimit - scannedDocuments;
    let artifactsQuery = teamDoc.ref.collection("artifacts").orderBy(DOCUMENT_ID);
    if (pageCursor?.teamID === teamDoc.id && pageCursor.artifactID) {
      artifactsQuery = artifactsQuery.startAfter(pageCursor.artifactID);
    }
    const artifactsSnapshot = await artifactsQuery.limit(remainingScanBudget + 1).get();
    const artifactDocs = artifactsSnapshot.docs.slice(0, remainingScanBudget);
    const hasMoreArtifacts = artifactsSnapshot.docs.length > artifactDocs.length;
    let lastScannedArtifactID: string | null = null;

    for (const artifactDoc of artifactDocs) {
      if (scannedDocuments >= scanLimit) {
        truncated = true;
        nextCursor = { teamID: teamDoc.id, artifactID: lastScannedArtifactID };
        break;
      }
      scannedDocuments += 1;
      lastScannedArtifactID = artifactDoc.id;
      const data = artifactDoc.data();

      if (!isLegacyPlaintextArtifactData(data)) continue;

      const artifactID = typeof data["artifactID"] === "string" ? data["artifactID"] : artifactDoc.id;
      const revisionID = typeof data["revisionID"] === "string" ? data["revisionID"] : null;
      hits.push({
        artifactPath: artifactDoc.ref.path,
        artifactID,
        workspaceID,
        teamID: teamDoc.id,
        revisionID,
        hasTitle: typeof data["title"] === "string",
        hasBody: typeof data["body"] === "string",
        hasContentHash: typeof data["contentHash"] === "string",
      });

      if (hits.length >= resultLimit) {
        truncated = true;
        nextCursor = { teamID: teamDoc.id, artifactID: artifactDoc.id };
        break;
      }
    }

    if (nextCursor) {
      break;
    }

    if (hasMoreArtifacts) {
      truncated = true;
      nextCursor = { teamID: teamDoc.id, artifactID: lastScannedArtifactID };
      break;
    }

    const hasLaterTeamsInPage = teamIndex < teamDocs.length - 1;
    if (scannedDocuments >= scanLimit && (hasLaterTeamsInPage || hasMoreTeams)) {
      truncated = true;
      nextCursor = { teamID: teamDoc.id, artifactID: null };
      break;
    }

    if (hasMoreTeams && teamIndex === teamDocs.length - 1) {
      truncated = true;
      nextCursor = { teamID: teamDoc.id, artifactID: null };
      break;
    }
  }

  return {
    scannedDocuments,
    legacyPlaintextCount: hits.length,
    hits,
    truncated,
    nextPageToken: encodePageToken(nextCursor),
    scannedAt: now.toISOString(),
  };
}

export const scanLegacyPlaintextArtifacts = onCallProduction(
  "scanLegacyPlaintextArtifacts",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 10,
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (
    request: CallableRequest<{
      scanLimit?: unknown;
      resultLimit?: unknown;
      pageToken?: unknown;
    }>,
  ): Promise<LegacyPlaintextScanResult> => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in to scan shared artifacts.");
    }

    const scanLimit =
      boundedInteger(request.data?.scanLimit, "scanLimit", 1, MAX_SCAN_LIMIT, false) ?? DEFAULT_SCAN_LIMIT;
    const resultLimit =
      boundedInteger(request.data?.resultLimit, "resultLimit", 1, MAX_RESULT_LIMIT, false) ?? DEFAULT_RESULT_LIMIT;

    return scanLegacyPlaintextArtifactsForUser(getFirestore(), uid, scanLimit, resultLimit, request.data?.pageToken);
  },
);
