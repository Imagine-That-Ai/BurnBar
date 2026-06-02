/**
 * @fileoverview Computer Use — OpenTimestamps proof validation.
 *
 * The Mac owns the audit chain and writes the `.ots` proof beside the local
 * chain. This callable gives support and signed-in clients a server-side
 * cross-check: does the submitted proof match the session head we saw in
 * Firestore, and can the configured OpenTimestamps verifier confirm it?
 *
 * OpenTimestamps proof parsing is intentionally delegated to the official
 * `ots` CLI when present. Cloud Functions images do not ship that binary by
 * default, so the function reports `ots_verifier_unavailable` rather than
 * pretending opaque proof bytes are Bitcoin-confirmed.
 */

import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash } from "node:crypto";
import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import type { CallableRequest } from "firebase-functions/v2/https";
import { defineString } from "firebase-functions/params";
import { getConfig } from "./config.js";
import { enforceHighRiskComputerUseCallable } from "./appCheckAttestation.js";
import { logCallableStart, traceIdFromCallableRequest, wrapCallableHandler } from "./logging.js";
import { resilientFetch } from "./resilienceHelpers.js";
import { readOpenBurnBarFunctionsConfig } from "./firebaseRuntime.js";
import { isRecord, jsonObject, stringField } from "./guards.js";
import type {
  ComputerUseOpenTimestampsValidationRequest,
  ComputerUseOpenTimestampsValidationResponse,
  ComputerUseOpenTimestampsValidationStatus,
} from "./types.js";

const execFileAsync = promisify(execFile);

const DEFAULT_MAX_PROOF_BYTES = 256 * 1024;
const DEFAULT_MAX_CHAIN_BYTES = 10 * 1024 * 1024;
const OPENBURNBAR_OTS_VERIFY_URL_PARAM = defineString("OPENBURNBAR_OTS_VERIFY_URL", {
  default: "",
});
const OPENBURNBAR_OTS_VERIFY_AUDIENCE_PARAM = defineString("OPENBURNBAR_OTS_VERIFY_AUDIENCE", { default: "" });

export type ComputerUseOpenTimestampsVerifier = (
  proofBytes: Buffer,
  chainBytes?: Buffer,
) => Promise<Pick<ComputerUseOpenTimestampsValidationResponse, "status" | "verified" | "otsVerifierOutput">>;

export type ComputerUseOpenTimestampsServerHeadLookup = (
  uid: string,
  sessionId: string,
  claimedHead: string,
) => Promise<{
  status: ComputerUseOpenTimestampsValidationStatus | "server_head_matched";
  serverAuditHeadHashHex?: string;
  sessionManifestHashHex?: string;
}>;

export interface ComputerUseOpenTimestampsValidationDependencies {
  verifyProof?: ComputerUseOpenTimestampsVerifier;
  serverHeadStatus?: ComputerUseOpenTimestampsServerHeadLookup;
  now?: () => Date;
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value == null) return undefined;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${field} must be a string.`);
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function decodeBase64(value: string, field: string, maxBytes: number): Buffer {
  const decoded = Buffer.from(value, "base64");
  if (decoded.length === 0) {
    throw new HttpsError("invalid-argument", `${field} decoded to empty bytes.`);
  }
  if (decoded.length > maxBytes) {
    throw new HttpsError("invalid-argument", `${field} is too large (${decoded.length} bytes > ${maxBytes}).`);
  }
  return decoded;
}

export function parseComputerUseOpenTimestampsValidationRequest(
  raw: unknown,
): ComputerUseOpenTimestampsValidationRequest {
  const data = isRecord(raw) ? raw : {};
  return {
    uid: requiredString(data.uid, "uid"),
    sessionId: requiredString(data.sessionId, "sessionId"),
    auditHeadHashHex: requiredString(data.auditHeadHashHex, "auditHeadHashHex"),
    proofBase64: requiredString(data.proofBase64, "proofBase64"),
    chainFileBase64: optionalString(data.chainFileBase64, "chainFileBase64"),
  };
}

function otsBinaryPath(): string | undefined {
  const cfg = readOpenBurnBarFunctionsConfig();
  const configured = (process.env.OPENBURNBAR_OTS_VERIFY_BIN ?? stringField(cfg, "ots_verify_bin"))?.trim();
  if (configured) return configured;
  return "ots";
}

function otsVerifierServiceURL(): string | undefined {
  const cfg = readOpenBurnBarFunctionsConfig();
  const configured = (
    process.env.OPENBURNBAR_OTS_VERIFY_URL ??
    stringField(cfg, "ots_verify_url") ??
    OPENBURNBAR_OTS_VERIFY_URL_PARAM.value()
  )?.trim();
  return configured && configured.length > 0 ? configured : undefined;
}

function otsVerifierServiceAudience(serviceURL: string): string | undefined {
  const cfg = readOpenBurnBarFunctionsConfig();
  const configured = (
    process.env.OPENBURNBAR_OTS_VERIFY_AUDIENCE ??
    stringField(cfg, "ots_verify_audience") ??
    OPENBURNBAR_OTS_VERIFY_AUDIENCE_PARAM.value()
  )?.trim();
  if (configured && configured.length > 0) return configured;
  return undefined;
}

async function fetchGoogleIdentityToken(audience: string): Promise<string> {
  const url = new URL("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity");
  url.searchParams.set("audience", audience);
  url.searchParams.set("format", "full");
  const response = await resilientFetch("gcp.metadata.identity", url, {
    headers: { "Metadata-Flavor": "Google" },
  });
  if (!response.ok) {
    throw new Error(`metadata identity token request failed: HTTP ${response.status}`);
  }
  const token = (await response.text()).trim();
  if (!token) throw new Error("metadata identity token request returned empty token");
  return token;
}

async function runOtsVerifyViaService(
  serviceURL: string,
  proofBytes: Buffer,
  chainBytes?: Buffer,
): Promise<Awaited<ReturnType<ComputerUseOpenTimestampsVerifier>>> {
  let url: URL;
  try {
    url = new URL(serviceURL);
  } catch {
    return {
      status: "ots_verifier_unavailable",
      verified: false,
      otsVerifierOutput: "OPENBURNBAR_OTS_VERIFY_URL is not a valid URL.",
    };
  }

  const headers: Record<string, string> = { "content-type": "application/json" };
  const audience = otsVerifierServiceAudience(serviceURL);
  if (audience) {
    try {
      headers.authorization = `Bearer ${await fetchGoogleIdentityToken(audience)}`;
    } catch (error) {
      return {
        status: "ots_verifier_unavailable",
        verified: false,
        otsVerifierOutput: error instanceof Error ? error.message : "metadata identity token request failed",
      };
    }
  }

  const response = await resilientFetch("ots.verify", url, {
    method: "POST",
    headers,
    body: JSON.stringify({
      proofBase64: proofBytes.toString("base64"),
      chainFileBase64: chainBytes?.toString("base64"),
    }),
  });
  const text = await response.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = text.length > 0 ? jsonObject(JSON.parse(text)) : {};
  } catch {
    parsed = { output: text };
  }
  if (!response.ok) {
    return {
      status: response.status === 503 ? "ots_verifier_unavailable" : "ots_verify_failed",
      verified: false,
      otsVerifierOutput: String(parsed.output ?? parsed.error ?? text),
    };
  }
  const verified = parsed.verified === true;
  return {
    status: verified ? "verified" : "ots_verify_failed",
    verified,
    otsVerifierOutput: String(parsed.output ?? ""),
  };
}

export async function runOtsVerify(
  proofBytes: Buffer,
  chainBytes?: Buffer,
): Promise<Awaited<ReturnType<ComputerUseOpenTimestampsVerifier>>> {
  const serviceURL = otsVerifierServiceURL();
  if (serviceURL) {
    return runOtsVerifyViaService(serviceURL, proofBytes, chainBytes);
  }

  const binary = otsBinaryPath();
  if (!binary) {
    return { status: "ots_verifier_unavailable", verified: false };
  }

  const dir = await mkdtemp(join(tmpdir(), "openburnbar-ots-"));
  try {
    const proofPath = join(dir, "chain.jsonl.ots");
    const chainPath = join(dir, "chain.jsonl");
    await writeFile(proofPath, proofBytes, { mode: 0o600 });
    if (chainBytes) {
      await writeFile(chainPath, chainBytes, { mode: 0o600 });
    }

    const { stdout, stderr } = await execFileAsync(binary, ["verify", proofPath], {
      cwd: dir,
      timeout: 30_000,
      maxBuffer: 1024 * 1024,
    });
    const output = [stdout, stderr].filter(Boolean).join("\n").trim();
    return {
      status: "verified",
      verified: true,
      otsVerifierOutput: output || "ots verify exited 0",
    };
  } catch (error) {
    const nodeError = isRecord(error) ? error : {};
    const code = "code" in nodeError ? nodeError.code : undefined;
    if (code === "ENOENT") {
      return { status: "ots_verifier_unavailable", verified: false };
    }
    const stdout = typeof nodeError.stdout === "string" ? nodeError.stdout : undefined;
    const stderr = typeof nodeError.stderr === "string" ? nodeError.stderr : undefined;
    const message = error instanceof Error ? error.message : String(error);
    const output = [stdout, stderr, message].filter(Boolean).join("\n").trim();
    return {
      status: "ots_verify_failed",
      verified: false,
      otsVerifierOutput: output,
    };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export async function serverHeadStatus(
  uid: string,
  sessionId: string,
  claimedHead: string,
): Promise<Awaited<ReturnType<ComputerUseOpenTimestampsServerHeadLookup>>> {
  const doc = await getFirestore().doc(`users/${uid}/computer_use_sessions/${sessionId}`).get();
  if (!doc.exists) {
    return { status: "session_not_found" };
  }
  const session = doc.data();
  const serverHead = isRecord(session) ? stringField(session, "auditHeadHashHex") : undefined;
  const manifestHash = isRecord(session) ? stringField(session, "manifestHashHex") : undefined;
  if (!serverHead || !manifestHash) {
    return { status: "server_head_missing" };
  }
  if (serverHead !== claimedHead) {
    return {
      status: "head_mismatch",
      serverAuditHeadHashHex: serverHead,
    };
  }
  return {
    status: "server_head_matched",
    serverAuditHeadHashHex: serverHead,
    sessionManifestHashHex: manifestHash,
  };
}

interface DerivedAuditHead {
  ok: boolean;
  headHashHex?: string;
  reason?: string;
}

export function deriveComputerUseAuditHeadFromChainBytes(
  chainBytes: Buffer,
  sessionManifestHashHex: string,
): DerivedAuditHead {
  if (!/^[a-fA-F0-9]{64}$/.test(sessionManifestHashHex)) {
    return { ok: false, reason: "invalid_manifest_hash" };
  }
  const text = chainBytes.toString("utf8");
  let expectedIndex = 0;
  let parentHashHex = sessionManifestHashHex.toLowerCase();
  const lines = text.split("\n").filter((line) => line.trim().length > 0);
  for (const line of lines) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      return { ok: false, reason: "decode_failure" };
    }
    const entry = isRecord(parsed) ? parsed : undefined;
    if (!entry) return { ok: false, reason: "decode_failure" };
    const schemaVersion = typeof entry.schemaVersion === "number" ? entry.schemaVersion : undefined;
    if (schemaVersion !== 1) return { ok: false, reason: "unsupported_schema" };
    const entryIndex = typeof entry.entryIndex === "number" ? entry.entryIndex : undefined;
    if (entryIndex !== expectedIndex) return { ok: false, reason: "unexpected_entry_index" };
    const parent = typeof entry.parentEntryHashHex === "string" ? entry.parentEntryHashHex.toLowerCase() : "";
    if (parent !== parentHashHex) return { ok: false, reason: "parent_hash_mismatch" };
    parentHashHex = createHash("sha256").update(Buffer.from(line, "utf8")).digest("hex");
    expectedIndex += 1;
  }
  return { ok: true, headHashHex: parentHashHex };
}

export async function validateComputerUseOpenTimestampsProofForRequest(
  request: ComputerUseOpenTimestampsValidationRequest,
  dependencies: ComputerUseOpenTimestampsValidationDependencies = {},
): Promise<ComputerUseOpenTimestampsValidationResponse> {
  const proofBytes = decodeBase64(request.proofBase64, "proofBase64", DEFAULT_MAX_PROOF_BYTES);
  const chainBytes =
    request.chainFileBase64 == null
      ? undefined
      : decodeBase64(request.chainFileBase64, "chainFileBase64", DEFAULT_MAX_CHAIN_BYTES);

  const lookupServerHead = dependencies.serverHeadStatus ?? serverHeadStatus;
  const verifyProof = dependencies.verifyProof ?? runOtsVerify;
  const checkedAt = (dependencies.now ?? (() => new Date()))().toISOString();

  const head = await lookupServerHead(request.uid, request.sessionId, request.auditHeadHashHex);
  if (head.status !== "server_head_matched") {
    return {
      status: head.status,
      verified: false,
      sessionId: request.sessionId,
      auditHeadHashHex: request.auditHeadHashHex,
      serverAuditHeadHashHex: head.serverAuditHeadHashHex,
      proofSizeBytes: proofBytes.length,
      checkedAt,
    };
  }
  const shouldBindChainToHead =
    head.sessionManifestHashHex !== undefined || dependencies.serverHeadStatus === undefined;
  if (shouldBindChainToHead && !chainBytes) {
    return {
      status: "head_mismatch",
      verified: false,
      sessionId: request.sessionId,
      auditHeadHashHex: request.auditHeadHashHex,
      serverAuditHeadHashHex: head.serverAuditHeadHashHex,
      proofSizeBytes: proofBytes.length,
      checkedAt,
      otsVerifierOutput: "chainFileBase64 is required to bind the OpenTimestamps proof to the claimed audit head.",
    };
  }
  const derived =
    shouldBindChainToHead && chainBytes
      ? deriveComputerUseAuditHeadFromChainBytes(chainBytes, head.sessionManifestHashHex ?? "")
      : undefined;
  if (derived && (!derived.ok || derived.headHashHex !== request.auditHeadHashHex.toLowerCase())) {
    return {
      status: "head_mismatch",
      verified: false,
      sessionId: request.sessionId,
      auditHeadHashHex: request.auditHeadHashHex,
      serverAuditHeadHashHex: head.serverAuditHeadHashHex,
      proofSizeBytes: proofBytes.length,
      checkedAt,
      otsVerifierOutput: `submitted chain does not derive the claimed audit head (${derived.reason ?? "head_hash_mismatch"}).`,
    };
  }

  const otsResult = await verifyProof(proofBytes, chainBytes);
  return {
    ...otsResult,
    sessionId: request.sessionId,
    auditHeadHashHex: request.auditHeadHashHex,
    serverAuditHeadHashHex: head.serverAuditHeadHashHex,
    proofSizeBytes: proofBytes.length,
    checkedAt,
  };
}

export const validateOpenTimestampsProof = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    timeoutSeconds: 60,
    memory: "512MiB",
  },
  wrapCallableHandler(
    "validateOpenTimestampsProof",
    async (request: CallableRequest): Promise<ComputerUseOpenTimestampsValidationResponse> => {
      const parsed = parseComputerUseOpenTimestampsValidationRequest(request.data);
      logCallableStart("validateOpenTimestampsProof", traceIdFromCallableRequest(request), parsed.uid);
      enforceHighRiskComputerUseCallable(request, parsed.uid);
      return validateComputerUseOpenTimestampsProofForRequest(parsed);
    },
  ),
);
