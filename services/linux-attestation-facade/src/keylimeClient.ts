import { request as httpsRequest, type RequestOptions } from "node:https";
import { PublicError } from "./errors.js";
import type { AttestationPolicy, KeylimeEvidenceInput, KeylimeResult, KeylimeVerifier, RegistrarClient } from "./ports.js";
import { exactKeys, object, sha256 } from "./validation.js";

export interface MtlsCredentials { ca: Buffer; cert: Buffer; key: Buffer }

export interface KeylimeClientOptions {
  baseUrl: URL;
  credentials: MtlsCredentials;
  timeoutMillis: number;
  maxResponseBytes: number;
}

export interface KeylimeTpmVerifyData {
  nonce: string;
  quote: string;
  hash_alg: "sha256";
  tpm_ak: string;
  tpm_ek: string;
  tpm_policy: string;
  runtime_policy: string;
  mb_policy: string;
  ima_measurement_list: string;
  mb_list: string;
}

export interface KeylimeTpmVerifyRequest {
  type: "tpm";
  data: KeylimeTpmVerifyData;
}

export function buildKeylimeRegistrarRequest(ekCertificateBase64: string, ekTpmBase64: string, akTpmBase64: string): Record<string, string> {
  return { ekcert: ekCertificateBase64, ek_tpm: ekTpmBase64, aik_tpm: akTpmBase64 };
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const source = value as Record<string, unknown>;
  return `{${Object.keys(source).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(source[key])}`).join(",")}}`;
}

function imaText(bytes: Buffer): string {
  let result: string;
  try {
    result = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new PublicError(400, "bad_request", "IMA measurement list is invalid");
  }
  if (result.length === 0 || result.includes("\0")) {
    throw new PublicError(400, "bad_request", "IMA measurement list is invalid");
  }
  return result;
}

export function keylimeResponseLimitForRequest(requestBytes: number, hardLimit: number): number {
  if (!Number.isSafeInteger(requestBytes) || requestBytes <= 0
      || !Number.isSafeInteger(hardLimit) || hardLimit < 64 * 1024) {
    throw new Error("Invalid Keylime response limit inputs");
  }
  // Keylime 7.14.3 echoes the submitted evidence in successful `claims`.
  // Eight MiB covers the response envelope, Python JSON whitespace, and the
  // maximum non-ASCII expansion of the Firestore-bounded policy document.
  return Math.min(hardLimit, Math.max(64 * 1024, requestBytes + 8 * 1024 * 1024));
}

export function buildKeylimeTpmVerifyRequest(evidence: KeylimeEvidenceInput, policy: AttestationPolicy): KeylimeTpmVerifyRequest {
  return {
    type: "tpm",
    data: {
      nonce: Buffer.from(evidence.qualifyingDataSha256, "hex").toString("base64"),
      quote: `r${evidence.quoteAttestationBase64}:${evidence.quoteSignatureBase64}:${evidence.quotePcrValuesBase64}`,
      hash_alg: evidence.pcrBank,
      tpm_ak: evidence.akTpmBase64,
      tpm_ek: evidence.ekTpmBase64,
      tpm_policy: JSON.stringify(policy.tpmPolicy),
      runtime_policy: JSON.stringify(policy.runtimePolicy),
      mb_policy: JSON.stringify(policy.measuredBootPolicy),
      ima_measurement_list: imaText(evidence.imaMeasurementList),
      mb_list: evidence.measuredBootLog.toString("base64"),
    },
  };
}

export function parseKeylimeTpmVerifyResponse(response: unknown, submitted: KeylimeTpmVerifyRequest): KeylimeResult {
  const envelope = object(response, "Keylime response");
  exactKeys(envelope, ["code", "status", "results"], "Keylime response");
  if (envelope.code !== 200 || envelope.status !== "Success") throw new Error("Keylime operation failed");
  const result = object(envelope.results, "Keylime results");
  exactKeys(result, ["valid", "failures", "claims"], "Keylime verification result");
  if (typeof result.valid !== "boolean" || !Array.isArray(result.failures)) throw new Error("Invalid Keylime verification response");
  if (!result.valid) return { valid: false, receipt: { claimsHash: sha256("rejected") } };
  const claims = object(result.claims, "Keylime claims");
  if (result.failures.length !== 0 || canonicalJson(claims) !== canonicalJson(submitted.data)) throw new Error("Invalid Keylime verification claims");
  return { valid: true, receipt: { claimsHash: sha256(canonicalJson(claims)) } };
}

export class KeylimeClient implements KeylimeVerifier, RegistrarClient {
  constructor(private readonly options: KeylimeClientOptions) {
    if (options.baseUrl.protocol !== "https:" || options.baseUrl.username !== "" || options.baseUrl.password !== "" || options.baseUrl.search !== "" || options.baseUrl.hash !== "") {
      throw new Error("Keylime base URL must be a fixed HTTPS origin");
    }
  }

  async begin(agentId: string, ekCertificateBase64: string, ekTpmBase64: string, akTpmBase64: string): Promise<{ activationBlob: string }> {
    const response = await this.call("POST", `/v2.5/agents/${encodeURIComponent(agentId)}`, buildKeylimeRegistrarRequest(ekCertificateBase64, ekTpmBase64, akTpmBase64));
    const envelope = this.resultEnvelope(response);
    exactKeys(envelope, ["blob"], "Keylime registrar result");
    if (typeof envelope.blob !== "string" || envelope.blob.length === 0 || envelope.blob.length > 1_000_000) throw new Error("Invalid Keylime activation blob");
    return { activationBlob: envelope.blob };
  }

  async activate(agentId: string, activationProof: string): Promise<void> {
    this.resultEnvelope(await this.call("PUT", `/v2.5/agents/${encodeURIComponent(agentId)}/activate`, { auth_tag: activationProof }));
  }

  async verify(evidence: KeylimeEvidenceInput, policy: AttestationPolicy): Promise<KeylimeResult> {
    const submitted = buildKeylimeTpmVerifyRequest(evidence, policy);
    return parseKeylimeTpmVerifyResponse(await this.call("POST", "/v2.5/verify/evidence", submitted), submitted);
  }

  private resultEnvelope(response: unknown): Record<string, unknown> {
    const envelope = object(response, "Keylime response");
    exactKeys(envelope, ["code", "status", "results"], "Keylime response");
    if (envelope.code !== 200) throw new Error("Keylime operation failed");
    return object(envelope.results, "Keylime results");
  }

  private async call(method: "POST" | "PUT", path: string, body: unknown): Promise<unknown> {
    const bytes = Buffer.from(JSON.stringify(body), "utf8");
    const responseLimit = keylimeResponseLimitForRequest(bytes.byteLength, this.options.maxResponseBytes);
    const url = new URL(path, this.options.baseUrl);
    const requestOptions: RequestOptions = {
      protocol: "https:",
      hostname: this.options.baseUrl.hostname,
      port: this.options.baseUrl.port === "" ? 443 : Number(this.options.baseUrl.port),
      path: url.pathname,
      method,
      ca: this.options.credentials.ca,
      cert: this.options.credentials.cert,
      key: this.options.credentials.key,
      rejectUnauthorized: true,
      servername: this.options.baseUrl.hostname,
      headers: { "content-type": "application/json", "content-length": String(bytes.byteLength), "accept": "application/json" },
    };
    return new Promise((resolve, reject) => {
      const request = httpsRequest(requestOptions, response => {
        const chunks: Buffer[] = [];
        let size = 0;
        response.on("data", (chunk: Buffer) => {
          size += chunk.byteLength;
          if (size > responseLimit) response.destroy(new Error("Keylime response too large"));
          else chunks.push(chunk);
        });
        response.on("error", reject);
        response.on("end", () => {
          if (response.statusCode !== 200) {
            return reject(response.statusCode !== undefined && response.statusCode >= 400 && response.statusCode < 500
              ? new PublicError(400, "bad_request", "Keylime rejected the enrollment request")
              : new PublicError(503, "dependency_unavailable", "Attestation verifier is temporarily unavailable", true));
          }
          try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown); }
          catch { reject(new Error("Invalid Keylime JSON")); }
        });
      });
      request.setTimeout(this.options.timeoutMillis, () => request.destroy(new Error("Keylime timeout")));
      request.on("error", () => reject(new PublicError(503, "dependency_unavailable", "Attestation verifier is temporarily unavailable", true)));
      request.end(bytes);
    });
  }
}
