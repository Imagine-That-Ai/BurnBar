export const PROTOCOL_VERSION = 1;
export const REALTIME_CAPABILITY = "realtime_relay";
export const DEFAULT_MAX_FRAME_BYTES = 512 * 1024;
export const MAX_RELAY_ERROR_LENGTH = 2_048;
export const MAX_RELAY_CAPABILITIES = 32;
export const MAX_RELAY_CAPABILITY_LENGTH = 64;
export const MAX_RELAY_IDENTIFIER_LENGTH = 160;
export const MAX_RELAY_SEQUENCE = 100_000;

export type HermesRelayOperation =
  | "chatCompletions"
  | "models"
  | "sessions"
  | "sessionDetail"
  | "profiles"
  | "jobs";

export type HermesRelayChunkKind = "sse" | "data" | "error";

export type HermesRelaySocketRole = "host" | "client";

// Plan 2 §8: a single Cloud Run relay multiplexes Hermes and Pi sessions.
// Frames may carry an explicit `runtime` discriminator so channel keys are
// namespaced and a single host cannot accidentally cross-mount the other
// runtime's traffic. Missing runtime defaults to `hermes` for back-compat.
export type HermesRelayRuntime = "hermes" | "pi";
const RELAY_RUNTIMES = new Set<HermesRelayRuntime>(["hermes", "pi"]);
export const DEFAULT_RELAY_RUNTIME: HermesRelayRuntime = "hermes";

export function normalizeRuntime(value: unknown): HermesRelayRuntime {
  return typeof value === "string" && RELAY_RUNTIMES.has(value as HermesRelayRuntime)
    ? (value as HermesRelayRuntime)
    : DEFAULT_RELAY_RUNTIME;
}

export type HermesRealtimeFrameType =
  | "host.register"
  | "host.ready"
  | "request.start"
  | "request.cancel"
  | "response.chunk"
  | "response.complete"
  | "response.error"
  | "ping"
  | "pong";

export interface HermesRealtimePayload {
  operation?: HermesRelayOperation;
  method?: "GET" | "POST" | string;
  payloadCiphertext?: string;
  wrappedKey?: string;
  relayEncryption?: string;
  relayKeyVersion?: number;
  sequence?: number;
  kind?: HermesRelayChunkKind;
  ciphertext?: string;
  error?: string;
  chunkCount?: number;
  capabilities?: string[];
}

export interface HermesRealtimeFrame {
  type: HermesRealtimeFrameType;
  uid: string;
  connectionId: string;
  requestId?: string;
  protocolVersion: number;
  /// Optional runtime discriminator. Hosts and clients in the same relay
  /// session must agree on the value; when omitted, defaults to `hermes`.
  runtime?: HermesRelayRuntime;
  payload?: HermesRealtimePayload;
}

const FRAME_TYPES = new Set<HermesRealtimeFrameType>([
  "host.register",
  "host.ready",
  "request.start",
  "request.cancel",
  "response.chunk",
  "response.complete",
  "response.error",
  "ping",
  "pong",
]);

const RELAY_OPERATIONS = new Set<HermesRelayOperation>([
  "chatCompletions",
  "models",
  "sessions",
  "sessionDetail",
  "profiles",
  "jobs",
]);

const RELAY_CHUNK_KINDS = new Set<HermesRelayChunkKind>(["sse", "data", "error"]);
const RELAY_METHODS = new Set(["GET", "POST"]);
const SAFE_IDENTIFIER_PATTERN = /^[A-Za-z0-9._:-]{1,160}$/;
const BASE64ISH_PATTERN = /^[A-Za-z0-9+/=_-]+$/;

export function reqChannel(
  uid: string,
  connectionId: string,
  runtime: HermesRelayRuntime = DEFAULT_RELAY_RUNTIME
): string {
  return `${runtime}:req:${uid}:${connectionId}`;
}

export function respChannel(
  uid: string,
  requestId: string,
  runtime: HermesRelayRuntime = DEFAULT_RELAY_RUNTIME
): string {
  return `${runtime}:resp:${uid}:${requestId}`;
}

export function hostPresenceKey(
  uid: string,
  connectionId: string,
  runtime: HermesRelayRuntime = DEFAULT_RELAY_RUNTIME
): string {
  return `${runtime}:host:${uid}:${connectionId}`;
}

export function hostControlChannel(
  uid: string,
  connectionId: string,
  runtime: HermesRelayRuntime = DEFAULT_RELAY_RUNTIME
): string {
  return `${runtime}:ctrl:${uid}:${connectionId}`;
}

export function parseFrame(
  raw: Buffer | ArrayBuffer | Buffer[],
  maxFrameBytes: number = DEFAULT_MAX_FRAME_BYTES
): HermesRealtimeFrame {
  const byteLength = Array.isArray(raw)
    ? raw.reduce((total, chunk) => total + chunk.byteLength, 0)
    : raw.byteLength;
  if (byteLength > maxFrameBytes) {
    throw new Error("Frame exceeds realtime relay size limit.");
  }

  const text = Array.isArray(raw)
    ? Buffer.concat(raw).toString("utf8")
    : Buffer.from(raw as Buffer).toString("utf8");
  let parsed: Partial<HermesRealtimeFrame>;
  try {
    parsed = JSON.parse(text) as Partial<HermesRealtimeFrame>;
  } catch {
    throw new Error("Frame must be valid JSON.");
  }
  if (!parsed || typeof parsed !== "object") throw new Error("Frame must be a JSON object.");
  if (!isAllowedFrameType(parsed.type)) throw new Error("Unsupported realtime relay frame type.");
  assertSafeIdentifier(parsed.uid, "uid");
  assertSafeIdentifier(parsed.connectionId, "connectionId");
  if (parsed.requestId !== undefined) assertSafeIdentifier(parsed.requestId, "requestId");
  if (parsed.protocolVersion !== PROTOCOL_VERSION) throw new Error("Unsupported realtime relay protocol version.");
  if (parsed.runtime !== undefined && !RELAY_RUNTIMES.has(parsed.runtime as HermesRelayRuntime)) {
    throw new Error("Unsupported relay runtime discriminator.");
  }
  const frame = parsed as HermesRealtimeFrame;
  assertFrameShape(frame);
  return frame;
}

export function serializeFrame(frame: HermesRealtimeFrame): string {
  return JSON.stringify(frame);
}

export function assertFrameForUid(frame: HermesRealtimeFrame, uid: string): void {
  if (frame.uid !== uid) {
    throw new Error("Frame uid does not match authenticated user.");
  }
}

export function assertRoleCanSend(frame: HermesRealtimeFrame, role: HermesRelaySocketRole): void {
  switch (frame.type) {
    case "host.register":
    case "response.chunk":
    case "response.complete":
    case "response.error":
      if (role !== "host") throw new Error("Frame type is not allowed for this relay role.");
      return;
    case "request.start":
    case "request.cancel":
      if (role !== "client") throw new Error("Frame type is not allowed for this relay role.");
      return;
    case "ping":
    case "pong":
      return;
    case "host.ready":
      throw new Error("host.ready is server-originated.");
  }
}

export function assertRequestFrame(frame: HermesRealtimeFrame): void {
  if (!frame.requestId) throw new Error("requestId is required.");
  if (frame.type === "request.start") {
    if (!frame.payload?.operation || !RELAY_OPERATIONS.has(frame.payload.operation)) {
      throw new Error("operation is required.");
    }
    if (!frame.payload?.method || !RELAY_METHODS.has(frame.payload.method)) {
      throw new Error("method is required.");
    }
    assertBoundedBase64(frame.payload.payloadCiphertext, "payloadCiphertext", 450_000);
    assertBoundedBase64(frame.payload.wrappedKey, "wrappedKey", 4_096);
    if (frame.payload.relayEncryption !== "p256-hkdf-sha256-aesgcm") throw new Error("Unsupported relay encryption.");
    if (frame.payload.relayKeyVersion !== undefined && !isBoundedInteger(frame.payload.relayKeyVersion, 1, 32)) {
      throw new Error("relayKeyVersion is invalid.");
    }
  }
}

function assertFrameShape(frame: HermesRealtimeFrame): void {
  switch (frame.type) {
    case "host.register":
      assertCapabilities(frame.payload?.capabilities);
      return;
    case "request.start":
    case "request.cancel":
      assertRequestFrame(frame);
      return;
    case "response.chunk":
      assertResponseChunk(frame);
      return;
    case "response.complete":
      if (!frame.requestId) throw new Error("requestId is required.");
      if (!isBoundedInteger(frame.payload?.chunkCount, 0, MAX_RELAY_SEQUENCE)) {
        throw new Error("chunkCount is invalid.");
      }
      return;
    case "response.error":
      if (!frame.requestId) throw new Error("requestId is required.");
      if (frame.payload?.error !== undefined && !isBoundedString(frame.payload.error, MAX_RELAY_ERROR_LENGTH)) {
        throw new Error("error is too large.");
      }
      return;
    case "ping":
    case "pong":
    case "host.ready":
      return;
  }
}

function assertResponseChunk(frame: HermesRealtimeFrame): void {
  if (!frame.requestId) throw new Error("requestId is required.");
  if (!isBoundedInteger(frame.payload?.sequence, 0, MAX_RELAY_SEQUENCE)) {
    throw new Error("sequence is invalid.");
  }
  if (!frame.payload?.kind || !RELAY_CHUNK_KINDS.has(frame.payload.kind)) {
    throw new Error("kind is required.");
  }
  if (frame.payload.kind === "error") {
    if (frame.payload.error !== undefined && !isBoundedString(frame.payload.error, MAX_RELAY_ERROR_LENGTH)) {
      throw new Error("error is too large.");
    }
    return;
  }
  assertBoundedBase64(frame.payload.ciphertext, "ciphertext", 450_000);
}

function assertCapabilities(capabilities: unknown): void {
  if (capabilities === undefined) return;
  if (!Array.isArray(capabilities) || capabilities.length > MAX_RELAY_CAPABILITIES) {
    throw new Error("capabilities are invalid.");
  }
  for (const capability of capabilities) {
    if (!isBoundedString(capability, MAX_RELAY_CAPABILITY_LENGTH)) {
      throw new Error("capabilities are invalid.");
    }
  }
}

function assertSafeIdentifier(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || !SAFE_IDENTIFIER_PATTERN.test(value)) {
    throw new Error(`Frame ${field} is invalid.`);
  }
}

function assertBoundedBase64(value: unknown, field: string, maxLength: number): asserts value is string {
  if (!isBoundedString(value, maxLength) || !BASE64ISH_PATTERN.test(value)) {
    throw new Error(`${field} is invalid.`);
  }
}

function isBoundedString(value: unknown, maxLength: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength;
}

function isBoundedInteger(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

function isAllowedFrameType(value: unknown): value is HermesRealtimeFrameType {
  return typeof value === "string" && FRAME_TYPES.has(value as HermesRealtimeFrameType);
}
