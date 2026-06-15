import {
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  HERMES_GATEWAY_RATCHET_ALGORITHM,
  HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION,
  type GatewayRelayEnvelopeDoc,
  type GatewayRatchetEnvelopeDoc,
} from "../hermesGateway.js";

// A base64 X9.63 uncompressed P-256 public key: 65 bytes, first byte 0x04.
export const RELAY_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 7)]).toString("base64");
// A second, distinct X9.63 uncompressed P-256 public key for the v2 senderPublicKey
// wire hint (so a round-trip asserts the exact value flows through, not just any key).
export const SENDER_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 9)]).toString("base64");

// The canonical v2 relay envelope: the DEFAULT key version is now 2, which adds
// the optional senderPublicKey wire HINT (a base64 X9.63 P-256 key) that BOTH
// validators must round-trip verbatim.
export function relayEnvelope(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("wrappedkey").toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
    relayKeyVersion: 2,
    senderPublicKey: SENDER_PUBKEY_B64,
  };
}

// A legacy v1 relay envelope: no senderPublicKey hint (the field did not exist
// before v2); both validators must keep accepting it unchanged (no v1 brick).
export function relayEnvelopeV1(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("wrappedkey").toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
    relayKeyVersion: 1,
  };
}

export function relayEnvelopeV3(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("hpke-wrapped-key").toString("base64"),
    enc: Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 3)]).toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
    relayKeyVersion: 3,
    senderPublicKey: SENDER_PUBKEY_B64,
  };
}

export function ratchetEnvelope(): GatewayRatchetEnvelopeDoc {
  return {
    header: {
      version: HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION,
      algorithm: HERMES_GATEWAY_RATCHET_ALGORITHM,
      sessionID: "hgr_session-1",
      senderDeviceID: "agent-device",
      receiverDeviceID: "phone-device",
      ratchetPublicKeyBase64: RELAY_PUBKEY_B64,
      previousChainLength: 0,
      messageNumber: 0,
      epoch: 1,
    },
    ciphertextBase64: Buffer.from("ratchet-ciphertext").toString("base64"),
  };
}
