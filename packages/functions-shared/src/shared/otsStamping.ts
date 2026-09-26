/**
 * @fileoverview OpenTimestamps stamping helpers shared by the deployed
 * `validateOpenTimestampsProof` callable and the audit-log OTS anchor.
 * Extracted from computerUseOpenTimestamps (3.5 shared runtime) so no
 * deployed-function module is imported by shared code.
 */

import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { defineString } from "firebase-functions/params";

import { readOpenBurnBarFunctionsConfig } from "../firebaseRuntime.js";
import { isRecord, jsonObject, stringField } from "../guards.js";
import { resilientFetch } from "../resilienceHelpers.js";

export const execFileAsync = promisify(execFile);
const OPENBURNBAR_OTS_VERIFY_AUDIENCE_PARAM = defineString("OPENBURNBAR_OTS_VERIFY_AUDIENCE", { default: "" });
const OPENBURNBAR_OTS_STAMP_URL_PARAM = defineString("OPENBURNBAR_OTS_STAMP_URL", { default: "" });
const OTS_DIGEST_BYTES = 32;

/** Outcome of an OTS stamp: the detached `.ots` proof bytes, or why it was skipped. */
export interface OtsStampResult {
  status: "stamped" | "ots_stamper_unavailable" | "ots_stamp_failed";
  proofBytes?: Buffer;
  output?: string;
}
export function otsBinaryPath(): string | undefined {
  const cfg = readOpenBurnBarFunctionsConfig();
  const configured = (process.env.OPENBURNBAR_OTS_VERIFY_BIN ?? stringField(cfg, "ots_verify_bin"))?.trim();
  if (configured) return configured;
  return "ots";
}
function otsStampServiceURL(): string | undefined {
  const cfg = readOpenBurnBarFunctionsConfig();
  const configured = (
    process.env.OPENBURNBAR_OTS_STAMP_URL ??
    stringField(cfg, "ots_stamp_url") ??
    OPENBURNBAR_OTS_STAMP_URL_PARAM.value()
  )?.trim();
  return configured && configured.length > 0 ? configured : undefined;
}

export function otsVerifierServiceAudience(_serviceURL: string): string | undefined {
  const cfg = readOpenBurnBarFunctionsConfig();
  const configured = (
    process.env.OPENBURNBAR_OTS_VERIFY_AUDIENCE ??
    stringField(cfg, "ots_verify_audience") ??
    OPENBURNBAR_OTS_VERIFY_AUDIENCE_PARAM.value()
  )?.trim();
  if (configured && configured.length > 0) return configured;
  return undefined;
}
export async function fetchGoogleIdentityToken(audience: string): Promise<string> {
  const url = new URL("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity");
  url.searchParams.set("audience", audience);
  url.searchParams.set("format", "full");
  // L5: this is the ONE legitimate internal-host fetch (GCP workload identity);
  // it opts past the SSRF guard explicitly. No user input reaches this URL.
  const response = await resilientFetch(
    "gcp.metadata.identity",
    url,
    { headers: { "Metadata-Flavor": "Google" } },
    { allowPrivateHosts: true },
  );
  if (!response.ok) {
    throw new Error(`metadata identity token request failed: HTTP ${response.status}`);
  }
  const token = (await response.text()).trim();
  if (!token) throw new Error("metadata identity token request returned empty token");
  return token;
}
async function runOtsStampViaService(serviceURL: string, digest: Buffer): Promise<OtsStampResult> {
  let url: URL;
  try {
    url = new URL(serviceURL);
  } catch {
    return { status: "ots_stamper_unavailable", output: "OPENBURNBAR_OTS_STAMP_URL is not a valid URL." };
  }

  const headers: Record<string, string> = { "content-type": "application/json" };
  const audience = otsVerifierServiceAudience(serviceURL);
  if (audience) {
    try {
      headers.authorization = `Bearer ${await fetchGoogleIdentityToken(audience)}`;
    } catch (error) {
      return {
        status: "ots_stamper_unavailable",
        output: error instanceof Error ? error.message : "metadata identity token request failed",
      };
    }
  }

  const response = await resilientFetch("ots.stamp", url, {
    method: "POST",
    headers,
    body: JSON.stringify({ digestBase64: digest.toString("base64") }),
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
      status: response.status === 503 ? "ots_stamper_unavailable" : "ots_stamp_failed",
      output: String(parsed.output ?? parsed.error ?? text),
    };
  }
  const proofBase64 = typeof parsed.proofBase64 === "string" ? parsed.proofBase64 : "";
  if (parsed.stamped !== true || proofBase64.length === 0) {
    return { status: "ots_stamp_failed", output: String(parsed.output ?? "ots stamp returned no proof") };
  }
  return { status: "stamped", proofBytes: Buffer.from(proofBase64, "base64"), output: String(parsed.output ?? "") };
}

/**
 * Stamp a 32-byte SHA-256 digest with OpenTimestamps and return the detached
 * `.ots` proof. Reuses the same service-URL/CLI resolution as {@link runOtsVerify}
 * (the verifier Docker image ships the full `ots` client, which can stamp too).
 * Submitting only the digest keeps the stamped content off the calendar servers.
 * When neither a stamp service nor a local `ots` binary is available the call
 * reports `ots_stamper_unavailable` rather than fabricating a proof.
 */
export async function runOtsStamp(digest: Buffer): Promise<OtsStampResult> {
  if (digest.length !== OTS_DIGEST_BYTES) {
    return { status: "ots_stamp_failed", output: `digest must be ${OTS_DIGEST_BYTES} bytes (got ${digest.length})` };
  }

  const serviceURL = otsStampServiceURL();
  if (serviceURL) {
    return runOtsStampViaService(serviceURL, digest);
  }

  const binary = otsBinaryPath();
  if (!binary) {
    return { status: "ots_stamper_unavailable" };
  }

  const dir = await mkdtemp(join(tmpdir(), "openburnbar-ots-stamp-"));
  try {
    const digestPath = join(dir, "head.bin");
    const proofPath = join(dir, "head.bin.ots");
    await writeFile(digestPath, digest, { mode: 0o600 });

    const { stdout, stderr } = await execFileAsync(binary, ["stamp", digestPath], {
      cwd: dir,
      timeout: 60_000,
      maxBuffer: 1024 * 1024,
    });
    const output = [stdout, stderr].filter(Boolean).join("\n").trim();
    const proofBytes = await readFile(proofPath);
    return { status: "stamped", proofBytes, output: output || "ots stamp exited 0" };
  } catch (error) {
    const nodeError = isRecord(error) ? error : {};
    const code = "code" in nodeError ? nodeError.code : undefined;
    if (code === "ENOENT") {
      return { status: "ots_stamper_unavailable" };
    }
    const stdout = typeof nodeError.stdout === "string" ? nodeError.stdout : undefined;
    const stderr = typeof nodeError.stderr === "string" ? nodeError.stderr : undefined;
    const message = error instanceof Error ? error.message : String(error);
    return { status: "ots_stamp_failed", output: [stdout, stderr, message].filter(Boolean).join("\n").trim() };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
