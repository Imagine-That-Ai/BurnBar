import { createHash } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";

import { IROH_PAIRING_FRESHNESS_MS } from "../types.js";
import {
  boundedInteger,
  boundedStringArray,
  boundedFirestoreDocumentId,
  parsePhoneControlSigningKeyKind,
  requireDerivedPhoneControlPeerNodeId,
  requirePhoneControlAuthorityPublicKey,
  verifyEd25519RawSignature,
  verifyPhoneControlAuthoritySignature,
} from "./computerUseSecurityCodecs.js";

const IROH_NODE_ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";
const IROH_NODE_ID_BASE32_LENGTH = 52;
const IROH_NODE_ID_HEX_LENGTH = 64;
const IROH_NODE_ID_BYTE_LENGTH = 32;
const PAIRING_CLOCK_SKEW_MS = 30 * 1000;
const ROUTE_PROOF_DOMAIN = "OpenBurnBar-IrohControllerRoute-v1";
export const IROH_CONTROLLER_ROUTE_CHALLENGE_TTL_MS = 60 * 1000;
export const IROH_CONTROLLER_ROUTE_TTL_MS = 10 * 60 * 1000;

export function requireIrohTransportNodeId(raw: unknown): {
  nodeId: string;
  wireNodeId: string;
  publicKey: Buffer;
} {
  const wireNodeId = boundedFirestoreDocumentId(raw, "transportNodeId", IROH_NODE_ID_HEX_LENGTH);
  if (/^[0-9a-f]{64}$/u.test(wireNodeId)) {
    const publicKey = Buffer.from(wireNodeId, "hex");
    return { nodeId: publicKey.toString("hex"), wireNodeId, publicKey };
  }
  if (wireNodeId.length !== IROH_NODE_ID_BASE32_LENGTH || !/^[a-z2-7]{52}$/u.test(wireNodeId)) {
    throw new HttpsError(
      "invalid-argument",
      "transportNodeId must be a canonical lowercase hex or legacy base32 iroh NodeId.",
    );
  }

  const bytes: number[] = [];
  let accumulator = 0;
  let bitCount = 0;
  for (const character of wireNodeId) {
    const value = IROH_NODE_ID_ALPHABET.indexOf(character);
    if (value < 0) {
      throw new HttpsError("invalid-argument", "transportNodeId contains invalid base32 characters.");
    }
    accumulator = (accumulator << 5) | value;
    bitCount += 5;
    while (bitCount >= 8) {
      bitCount -= 8;
      bytes.push((accumulator >> bitCount) & 0xff);
      accumulator &= (1 << bitCount) - 1;
    }
  }
  if (bytes.length !== IROH_NODE_ID_BYTE_LENGTH || accumulator !== 0) {
    throw new HttpsError("invalid-argument", "transportNodeId has non-canonical base32 padding.");
  }
  const publicKey = Buffer.from(bytes);
  return { nodeId: publicKey.toString("hex"), wireNodeId, publicKey };
}

function framed(value: string): string {
  return `${Buffer.byteLength(value, "utf8")}:${value}\n`;
}

export function irohControllerRouteProofPayload(args: {
  challengeId: string;
  challengeNonce: string;
  uid: string;
  connectionId: string;
  sourceDeviceId: string;
  transportNodeId: string;
  authorityPeerNodeId: string;
  registrationGeneration: number;
  issuedAtMillis: number;
  expiresAtMillis: number;
}): Buffer {
  const fields = [
    "version",
    "1",
    "challengeId",
    args.challengeId,
    "challengeNonce",
    args.challengeNonce,
    "uid",
    args.uid,
    "connectionId",
    args.connectionId,
    "sourceDeviceId",
    args.sourceDeviceId,
    "transportNodeId",
    args.transportNodeId,
    "authorityPeerNodeId",
    args.authorityPeerNodeId,
    "registrationGeneration",
    String(args.registrationGeneration),
    "issuedAtMillis",
    String(args.issuedAtMillis),
    "expiresAtMillis",
    String(args.expiresAtMillis),
  ];
  return Buffer.from(`${ROUTE_PROOF_DOMAIN}\n${fields.map(framed).join("")}`, "utf8");
}

export function verifyIrohControllerRouteProof(
  transportPublicKey: Buffer,
  canonicalPayloadBase64: string,
  signatureBase64: string,
): boolean {
  const payload = Buffer.from(canonicalPayloadBase64, "base64");
  if (payload.toString("base64") !== canonicalPayloadBase64) return false;
  return verifyEd25519RawSignature(transportPublicKey, payload, signatureBase64);
}

export function requireVerifiedControllerAuthority(args: {
  connectionId: string;
  sourceDeviceId: string;
  authorityPeerNodeId: string;
  controller: Record<string, unknown>;
}): {
  sourceDeviceId: string;
  authorityPeerNodeId: string;
  authorityPublicKeySHA256: string;
  authorityPublicKey: Buffer;
  authorityKeyKind: "ed25519" | "se-p256";
} {
  const { controller } = args;
  if (
    controller.connectionId !== args.connectionId ||
    controller.deviceId !== args.sourceDeviceId ||
    controller.peerNodeId !== args.authorityPeerNodeId ||
    controller.id !== args.authorityPeerNodeId
  ) {
    throw new HttpsError("permission-denied", "Controller authority is not bound to this pairing and device.");
  }
  const keyKind = parsePhoneControlSigningKeyKind(controller.signingKeyKind);
  const { bytes } = requirePhoneControlAuthorityPublicKey(controller.publicKeyBase64, keyKind);
  requireDerivedPhoneControlPeerNodeId(args.authorityPeerNodeId, bytes, keyKind);
  return {
    sourceDeviceId: args.sourceDeviceId,
    authorityPeerNodeId: args.authorityPeerNodeId,
    authorityPublicKeySHA256: createHash("sha256").update(bytes).digest("hex"),
    authorityPublicKey: bytes,
    authorityKeyKind: keyKind,
  };
}

export function verifyIrohControllerAuthorityProof(
  authorityPublicKey: Buffer,
  authorityKeyKind: "ed25519" | "se-p256",
  canonicalPayloadBase64: string,
  signatureBase64: string,
): boolean {
  const payload = Buffer.from(canonicalPayloadBase64, "base64");
  if (payload.toString("base64") !== canonicalPayloadBase64) return false;
  return verifyPhoneControlAuthoritySignature(authorityPublicKey, authorityKeyKind, payload, signatureBase64);
}

export function requireActiveIrohPairing(args: {
  uid: string;
  connectionId: string;
  pairing: Record<string, unknown>;
  hostKey: Record<string, unknown>;
  nowMillis: number;
}): { connectionId: string; hostDeviceId: string; publishedAtMillis: number } {
  const { pairing, hostKey } = args;
  if (pairing.id !== args.connectionId || hostKey.id !== "host") {
    throw new HttpsError("failed-precondition", "Iroh pairing identity is inconsistent.");
  }
  const publishedAtMillis =
    boundedInteger(pairing.publishedAtMillis, "pairing.publishedAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0;
  if (
    publishedAtMillis < args.nowMillis - IROH_PAIRING_FRESHNESS_MS ||
    publishedAtMillis > args.nowMillis + PAIRING_CLOCK_SKEW_MS
  ) {
    throw new HttpsError("failed-precondition", "Iroh pairing is stale or from the future.");
  }
  const protocolVersion = boundedInteger(pairing.protocolVersion, "pairing.protocolVersion", 1, 1, true) ?? 1;
  const nodeId = requireIrohTransportNodeId(pairing.nodeId).wireNodeId;
  const connectionId = boundedFirestoreDocumentId(pairing.id, "pairing.id", 160);
  const relayURL = typeof pairing.relayURL === "string" ? pairing.relayURL.trim() : "";
  const directAddresses = boundedStringArray(pairing.directAddresses, "pairing.directAddresses", 16, 512);
  const normalizedAddresses = [...new Set(directAddresses.map((address) => address.trim()).filter(Boolean))].sort();
  const hostDeviceId = boundedFirestoreDocumentId(pairing.publishedByDeviceId, "pairing.publishedByDeviceId", 160);
  if (hostKey.publishedByDeviceId !== hostDeviceId) {
    throw new HttpsError("permission-denied", "Iroh pairing and host trust root were published by different devices.");
  }
  const { bytes: hostPublicKey } = requirePhoneControlAuthorityPublicKey(hostKey.publicKeyBase64, "ed25519");
  const canonical = Buffer.from(
    `openburnbar.iroh.pairing.v${protocolVersion}|${args.uid}|${connectionId}|${nodeId}|${relayURL}|${normalizedAddresses.join(",")}|${publishedAtMillis}`,
    "utf8",
  );
  if (
    typeof pairing.signature !== "string" ||
    !verifyEd25519RawSignature(hostPublicKey, canonical, pairing.signature)
  ) {
    throw new HttpsError("permission-denied", "Iroh pairing signature is invalid.");
  }
  return { connectionId, hostDeviceId, publishedAtMillis };
}
