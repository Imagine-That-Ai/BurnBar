import assert from "node:assert/strict";
import test from "node:test";
import { parseFrame, PROTOCOL_VERSION, serializeFrame } from "./protocol.js";

test("rejects unsafe Redis channel identifiers", () => {
  assert.throws(() => parseFrame(Buffer.from(JSON.stringify({
    type: "request.start",
    uid: "user-1",
    connectionId: "relay mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "models",
      method: "GET",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
    },
  }))), /connectionId is invalid/);
});

test("rejects unknown operations, methods, and oversized ciphertext", () => {
  assert.throws(() => parseFrame(Buffer.from(JSON.stringify({
    type: "request.start",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "adminDeleteEverything",
      method: "DELETE",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
    },
  }))), /operation is required/);

  assert.throws(() => parseFrame(Buffer.from(JSON.stringify({
    type: "request.start",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "models",
      method: "DELETE",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
    },
  }))), /method is required/);
});

test("enforces configured frame size", () => {
  const frame = serializeFrame({
    type: "response.error",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: { error: "x".repeat(100) },
  });
  assert.throws(() => parseFrame(Buffer.from(frame), 40), /size limit/);
});

test("accepts a valid encrypted request.start frame", () => {
  const frame = parseFrame(Buffer.from(serializeFrame({
    type: "request.start",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "rt_123",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "chatCompletions",
      method: "POST",
      payloadCiphertext: "abcd+/=",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
      relayKeyVersion: 1,
    },
  })));
  assert.equal(frame.type, "request.start");
});
