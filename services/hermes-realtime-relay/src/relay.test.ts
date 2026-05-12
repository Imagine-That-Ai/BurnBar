import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { HermesRealtimeRelaySession, type RelaySocket } from "./relay.js";
import { PROTOCOL_VERSION, serializeFrame, type HermesRelayRuntime } from "./protocol.js";
import type { RelayQuotaStore } from "./quota.js";
import type { RelayMessageBus } from "./redisHub.js";

class FakeBus implements RelayMessageBus {
  private readonly emitter = new EventEmitter();
  readonly values = new Map<string, string>();

  async publish(channel: string, message: string): Promise<number> {
    const count = this.emitter.listenerCount(channel);
    this.emitter.emit(channel, message);
    return count;
  }

  async subscribe(channel: string, listener: (message: string) => void): Promise<() => Promise<void>> {
    this.emitter.on(channel, listener);
    return async () => {
      this.emitter.off(channel, listener);
    };
  }

  async set(key: string, value: string): Promise<unknown> {
    this.values.set(key, value);
    return "OK";
  }

  async del(key: string): Promise<unknown> {
    this.values.delete(key);
    return 1;
  }

  async ping(): Promise<string> {
    return "PONG";
  }

  async disconnect(): Promise<void> {}
}

class FakeQuota implements RelayQuotaStore {
  frameLimitAfter = Number.POSITIVE_INFINITY;
  requestStarts = 0;
  inFlight = new Map<string, HermesRelayRuntime>();
  releasedSockets: string[] = [];
  releasedRuntimeSockets: string[] = [];

  async reserveSocket(): Promise<void> {}
  async refreshSocket(): Promise<void> {}
  async releaseSocket(_uid: string, role: "host" | "client", sessionID: string): Promise<void> {
    this.releasedSockets.push(`${role}:${sessionID}`);
  }
  async reserveRuntimeSocket(): Promise<void> {}
  async refreshRuntimeSocket(): Promise<void> {}
  async releaseRuntimeSocket(
    _uid: string,
    role: "host" | "client",
    sessionID: string,
    runtime: HermesRelayRuntime
  ): Promise<void> {
    this.releasedRuntimeSockets.push(`${runtime}:${role}:${sessionID}`);
  }
  async checkFrameBytes(): Promise<void> {
    this.frameLimitAfter -= 1;
    if (this.frameLimitAfter < 0) {
      throw new Error("byte limit");
    }
  }
  async checkRequestStart(): Promise<void> {
    this.requestStarts += 1;
  }
  async reserveInFlight(_uid: string, requestID: string, runtime: HermesRelayRuntime): Promise<void> {
    this.inFlight.set(requestID, runtime);
  }
  async releaseInFlight(_uid: string, requestID: string): Promise<void> {
    this.inFlight.delete(requestID);
  }
}

class FakeSocket extends EventEmitter implements RelaySocket {
  sent: string[] = [];
  closes: Array<{ code?: number; reason?: string }> = [];
  send(data: string): void { this.sent.push(data); }
  close(code?: number, reason?: string): void {
    this.closes.push({ code, reason });
    this.emit("close");
  }
}

async function flushRelay(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
  await new Promise<void>((resolve) => setImmediate(resolve));
}

function makeSession(
  socket: FakeSocket,
  bus: FakeBus,
  quota: FakeQuota,
  role: "host" | "client",
  sessionID: string
): HermesRealtimeRelaySession {
  return new HermesRealtimeRelaySession(socket, {
    uid: "user-1",
    role,
    sessionID,
    bus,
    quota,
    maxFrameBytes: 512 * 1024,
  });
}

function frameTypes(socket: FakeSocket): string[] {
  return socket.sent.map((frame) => JSON.parse(frame).type);
}

test("routes request frames to registered host and response frames back to requester", async () => {
  const bus = new FakeBus();
  const quota = new FakeQuota();
  const host = new FakeSocket();
  const client = new FakeSocket();
  makeSession(host, bus, quota, "host", "host-session").start();
  makeSession(client, bus, quota, "client", "client-session").start();

  host.emit("message", Buffer.from(serializeFrame({
    type: "host.register",
    uid: "user-1",
    connectionId: "relay-mac",
    protocolVersion: PROTOCOL_VERSION,
    payload: { capabilities: ["chat_completions", "realtime_relay"] },
  })));
  await flushRelay();

  client.emit("message", Buffer.from(serializeFrame({
    type: "request.start",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "models",
      method: "GET",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
      relayKeyVersion: 1,
    },
  })));
  await flushRelay();

  assert.ok(frameTypes(host).includes("host.ready"));
  assert.ok(frameTypes(host).includes("request.start"));
  assert.equal(quota.requestStarts, 1);
  assert.equal(quota.inFlight.get("req-1"), "hermes");

  host.emit("message", Buffer.from(serializeFrame({
    type: "response.chunk",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      sequence: 0,
      kind: "data",
      ciphertext: "encrypted-data",
    },
  })));
  host.emit("message", Buffer.from(serializeFrame({
    type: "response.complete",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: { chunkCount: 1 },
  })));
  await flushRelay();

  assert.equal(JSON.parse(client.sent.at(-2)!).payload.ciphertext, "encrypted-data");
  assert.equal(quota.inFlight.has("req-1"), false);

  host.close();
  client.close();
  await flushRelay();
  assert.deepEqual(quota.releasedSockets.sort(), ["client:client-session", "host:host-session"]);
  assert.deepEqual(
    quota.releasedRuntimeSockets.sort(),
    ["hermes:client:client-session", "hermes:host:host-session"]
  );
});

test("rejects cross-user frames and closes the violating socket", async () => {
  const socket = new FakeSocket();
  makeSession(socket, new FakeBus(), new FakeQuota(), "client", "client-session").start();

  socket.emit("message", Buffer.from(serializeFrame({
    type: "request.start",
    uid: "user-2",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "models",
      method: "GET",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
    },
  })));
  await flushRelay();

  assert.equal(JSON.parse(socket.sent[0]).payload.error, "Frame uid does not match authenticated user.");
  assert.equal(socket.closes[0].code, 1008);
});

test("fails request.start fast when no host is subscribed and releases in-flight quota", async () => {
  const quota = new FakeQuota();
  const socket = new FakeSocket();
  makeSession(socket, new FakeBus(), quota, "client", "client-session").start();

  socket.emit("message", Buffer.from(serializeFrame({
    type: "request.start",
    uid: "user-1",
    connectionId: "relay-mac",
    requestId: "req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: {
      operation: "models",
      method: "GET",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
      relayKeyVersion: 1,
    },
  })));
  await flushRelay();

  const response = JSON.parse(socket.sent.at(-1)!);
  assert.equal(response.type, "response.error");
  assert.equal(response.requestId, "req-1");
  assert.equal(response.payload.error, "Realtime Hermes host is not connected.");
  assert.equal(quota.inFlight.has("req-1"), false);
  socket.close();
});

test("prevents clients from registering as hosts", async () => {
  const socket = new FakeSocket();
  makeSession(socket, new FakeBus(), new FakeQuota(), "client", "client-session").start();

  socket.emit("message", Buffer.from(serializeFrame({
    type: "host.register",
    uid: "user-1",
    connectionId: "relay-mac",
    protocolVersion: PROTOCOL_VERSION,
    payload: { capabilities: ["realtime_relay"] },
  })));
  await flushRelay();

  assert.equal(JSON.parse(socket.sent[0]).payload.error, "Frame type is not allowed for this relay role.");
  assert.equal(socket.closes[0].code, 1008);
});

test("new host registration closes an older host session for the same connection", async () => {
  const bus = new FakeBus();
  const quota = new FakeQuota();
  const oldHost = new FakeSocket();
  const newHost = new FakeSocket();
  makeSession(oldHost, bus, quota, "host", "old-host").start();
  makeSession(newHost, bus, quota, "host", "new-host").start();

  for (const socket of [oldHost, newHost]) {
    socket.emit("message", Buffer.from(serializeFrame({
      type: "host.register",
      uid: "user-1",
      connectionId: "relay-mac",
      protocolVersion: PROTOCOL_VERSION,
      payload: { capabilities: ["realtime_relay"] },
    })));
    await flushRelay();
  }

  assert.equal(oldHost.closes[0].code, 4000);
  assert.ok(frameTypes(newHost).includes("host.ready"));
});

test("keeps Pi relay traffic on Pi runtime channels and quotas", async () => {
  const bus = new FakeBus();
  const quota = new FakeQuota();
  const host = new FakeSocket();
  const client = new FakeSocket();
  makeSession(host, bus, quota, "host", "pi-host-session").start();
  makeSession(client, bus, quota, "client", "pi-client-session").start();

  host.emit("message", Buffer.from(serializeFrame({
    type: "host.register",
    uid: "user-1",
    connectionId: "pi-relay-mac",
    protocolVersion: PROTOCOL_VERSION,
    runtime: "pi",
    payload: { capabilities: ["realtime_relay"] },
  })));
  await flushRelay();

  client.emit("message", Buffer.from(serializeFrame({
    type: "request.start",
    uid: "user-1",
    connectionId: "pi-relay-mac",
    requestId: "pi-req-1",
    protocolVersion: PROTOCOL_VERSION,
    runtime: "pi",
    payload: {
      operation: "models",
      method: "GET",
      payloadCiphertext: "cipher",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
      relayKeyVersion: 1,
    },
  })));
  await flushRelay();

  assert.equal(quota.inFlight.get("pi-req-1"), "pi");
  assert.ok(frameTypes(host).includes("request.start"));

  host.emit("message", Buffer.from(serializeFrame({
    type: "response.complete",
    uid: "user-1",
    connectionId: "pi-relay-mac",
    requestId: "pi-req-1",
    protocolVersion: PROTOCOL_VERSION,
    payload: { chunkCount: 0 },
  })));
  await flushRelay();

  assert.equal(quota.inFlight.has("pi-req-1"), false);

  host.close();
  client.close();
  await flushRelay();
  assert.deepEqual(
    quota.releasedRuntimeSockets.sort(),
    ["pi:client:pi-client-session", "pi:host:pi-host-session"]
  );
});

test("rejects sockets that try to switch relay runtimes", async () => {
  const socket = new FakeSocket();
  makeSession(socket, new FakeBus(), new FakeQuota(), "client", "client-session").start();

  for (const runtime of ["hermes", "pi"] as const) {
    socket.emit("message", Buffer.from(serializeFrame({
      type: "request.start",
      uid: "user-1",
      connectionId: "relay-mac",
      requestId: `req-${runtime}`,
      protocolVersion: PROTOCOL_VERSION,
      runtime,
      payload: {
        operation: "models",
        method: "GET",
        payloadCiphertext: "cipher",
        wrappedKey: "wrapped",
        relayEncryption: "p256-hkdf-sha256-aesgcm",
        relayKeyVersion: 1,
      },
    })));
    await flushRelay();
  }

  assert.equal(JSON.parse(socket.sent.at(-1)!).payload.error, "Relay socket runtime cannot change after registration.");
  assert.equal(socket.closes.at(-1)?.code, 1008);
});
