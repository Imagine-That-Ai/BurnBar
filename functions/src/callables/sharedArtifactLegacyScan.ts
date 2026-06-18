/**
 * @fileoverview Read-only scanner for legacy plaintext shared artifacts.
 *
 * The server cannot re-seal content because CloudVault keys never leave trusted
 * devices. This callable returns only document identifiers and metadata flags,
 * allowing clients to pull matching artifacts through the normal local
 * decrypt/re-seal path.
 */

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

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
  readonly scannedAt: string;
}

type LegacyScanQuerySnapshot<TDoc> = {
  readonly docs: readonly TDoc[];
};

type LegacyScanQuery<TDoc> = {
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

export function isLegacyPlaintextArtifactData(data: Record<string, unknown>): boolean {
  const isSealed = data["contentSealed"] === true || data["sealedPayload"] != null;
  if (isSealed) return false;
  return (
    typeof data["title"] === "string" || typeof data["body"] === "string" || typeof data["contentHash"] === "string"
  );
}

export async function scanLegacyPlaintextArtifactsForUser(
  db: LegacyScanDb,
  uid: string,
  scanLimit: number,
  resultLimit: number,
  now: Date = new Date(),
): Promise<LegacyPlaintextScanResult> {
  const workspaceID = `workspace-${uid}`;
  const hits: LegacyPlaintextArtifactHit[] = [];
  let scannedDocuments = 0;
  let truncated = false;

  const teamsSnapshot = await db
    .collection(`workspaces/${workspaceID}/teams`)
    .limit(MAX_TEAMS_PER_SCAN + 1)
    .get();
  const teamDocs = teamsSnapshot.docs.slice(0, MAX_TEAMS_PER_SCAN);
  if (teamsSnapshot.docs.length > MAX_TEAMS_PER_SCAN) {
    truncated = true;
  }

  for (const teamDoc of teamDocs) {
    if (hits.length >= resultLimit || scannedDocuments >= scanLimit) {
      truncated = true;
      break;
    }

    const remainingScanBudget = scanLimit - scannedDocuments;
    const artifactsSnapshot = await teamDoc.ref.collection("artifacts").limit(remainingScanBudget).get();
    if (artifactsSnapshot.docs.length === remainingScanBudget) {
      truncated = true;
    }

    for (const artifactDoc of artifactsSnapshot.docs) {
      if (scannedDocuments >= scanLimit) {
        truncated = true;
        break;
      }
      scannedDocuments += 1;
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
        break;
      }
    }

    if (truncated && (hits.length >= resultLimit || scannedDocuments >= scanLimit)) {
      break;
    }
  }

  return {
    scannedDocuments,
    legacyPlaintextCount: hits.length,
    hits,
    truncated,
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

    return scanLegacyPlaintextArtifactsForUser(getFirestore(), uid, scanLimit, resultLimit);
  },
);
