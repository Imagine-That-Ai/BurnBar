import { createHash, timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";
import { PublicError } from "./errors.js";

const TICKET_PREFIX = "obbat1_";
const TICKET_ID_BYTES = 16;
const TICKET_SECRET_BYTES = 32;
const SECRET_HASH_DOMAIN = Buffer.from("openburnbar.linux.attestation-ticket-secret.v1\0", "utf8");
const CLAIM_FINGERPRINT_DOMAIN = "openburnbar.linux.attestation-ticket-claim.v1";

export interface IngressTicketCredential {
  ticketId: string;
  secret: Buffer;
}

function unauthorizedTicket(): PublicError {
  return new PublicError(403, "forbidden", "Attestation ticket is not authorized");
}

function canonicalBase64url(value: string, byteLength: number): Buffer {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw unauthorizedTicket();
  const decoded = Buffer.from(value, "base64url");
  if (decoded.byteLength !== byteLength || decoded.toString("base64url") !== value) throw unauthorizedTicket();
  return decoded;
}

export function parseIngressTicket(value: unknown): IngressTicketCredential {
  if (typeof value !== "string" || value.includes(",")) throw unauthorizedTicket();
  const separator = value.indexOf(".");
  if (!value.startsWith(TICKET_PREFIX) || separator <= TICKET_PREFIX.length || value.indexOf(".", separator + 1) !== -1) {
    throw unauthorizedTicket();
  }
  const ticketId = value.slice(TICKET_PREFIX.length, separator);
  canonicalBase64url(ticketId, TICKET_ID_BYTES);
  const secretText = value.slice(separator + 1);
  return { ticketId, secret: canonicalBase64url(secretText, TICKET_SECRET_BYTES) };
}

export function ingressTicketFromRequest(request: IncomingMessage): IngressTicketCredential {
  return parseIngressTicket(request.headers["x-openburnbar-attestation-ticket"]);
}

export function ingressTicketSecretHash(secret: Buffer): string {
  if (secret.byteLength !== TICKET_SECRET_BYTES) throw new Error("Attestation ticket secret must be 32 bytes");
  return createHash("sha256").update(SECRET_HASH_DOMAIN).update(secret).digest("hex");
}

export function ticketHashesEqual(left: string, right: string): boolean {
  if (!/^[a-f0-9]{64}$/u.test(left) || !/^[a-f0-9]{64}$/u.test(right)) return false;
  return timingSafeEqual(Buffer.from(left, "hex"), Buffer.from(right, "hex"));
}

export function ingressTicketClaimFingerprint(purpose: "evidence_upload" | "enrollment_begin", fields: readonly string[]): string {
  const payload = [CLAIM_FINGERPRINT_DOMAIN, purpose, ...fields].join("\0");
  return createHash("sha256").update(payload, "utf8").digest("hex");
}

export function enrollmentMaterialHashes(input: {
  akTpmBase64: string;
  ekTpmBase64: string;
  ekCertificateBase64: string;
}): { akTpmSha256: string; ekTpmSha256: string; ekCertificateSha256: string } {
  return {
    akTpmSha256: createHash("sha256").update(Buffer.from(input.akTpmBase64, "base64")).digest("hex"),
    ekTpmSha256: createHash("sha256").update(Buffer.from(input.ekTpmBase64, "base64")).digest("hex"),
    ekCertificateSha256: createHash("sha256").update(Buffer.from(input.ekCertificateBase64, "base64")).digest("hex"),
  };
}
