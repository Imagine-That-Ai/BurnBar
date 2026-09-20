import { createHash, randomBytes } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import type { Duplex } from "node:stream";
import {
  firstHeaderValue,
  isAllowedOrigin,
  isAuthorized,
  isLoopbackHost,
  isLoopbackIp,
  type ProxyOptions,
} from "./proxyAuth.js";
import {
  dialectNotSupportedMessage,
  errorDetail,
  PROVIDER_NOT_CONFIGURED_MESSAGE,
  relayTarget,
  requestError,
} from "./proxyRelay.js";
import { validateResponsesBody } from "./proxyRoutes.js";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const OP_CONTINUATION = 0x0;
const OP_TEXT = 0x1;
const OP_BINARY = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;
const MAX_WS_MESSAGE_BYTES = 8 * 1024 * 1024;
const MAX_CONCURRENT_SOCKET_TURNS = 4;
const DEFAULT_WS_FETCH_TIMEOUT_MS = 30_000;

export function websocketAcceptKey(clientKey: string): string {
  return createHash("sha1").update(clientKey + WS_GUID).digest("base64");
}

export function encodeWsFrame(opcode: number, payload: Buffer, mask = false): Buffer {
  const length = payload.length;
  let headerSize = 2;
  if (length >= 65536) {
    headerSize += 8;
  } else if (length >= 126) {
    headerSize += 2;
  }
  if (mask) {
    headerSize += 4;
  }
  const frame = Buffer.alloc(headerSize + length);
  frame[0] = 0x80 | opcode;
  if (length < 126) {
    frame[1] = (mask ? 0x80 : 0) | length;
  } else if (length < 65536) {
    frame[1] = (mask ? 0x80 : 0) | 126;
    frame.writeUInt16BE(length, 2);
  } else {
    frame[1] = (mask ? 0x80 : 0) | 127;
    frame.writeUInt32BE(0, 2);
    frame.writeUInt32BE(length, 6);
  }
  let offset = headerSize - (mask ? 4 : 0);
  if (mask) {
    const key = randomBytes(4);
    key.copy(frame, offset);
    offset += 4;
    for (let i = 0; i < length; i += 1) {
      frame[offset + i] = (payload[i] ?? 0) ^ (key[i % 4] ?? 0);
    }
  } else {
    payload.copy(frame, offset);
  }
  return frame;
}

export function encodeWsText(text: string, mask = false): Buffer {
  return encodeWsFrame(OP_TEXT, Buffer.from(text, "utf8"), mask);
}

export interface DecodedWsFrame {
  fin: boolean;
  opcode: number;
  masked: boolean;
  payload: Buffer;
}

const KNOWN_OPCODES = new Set([
  OP_CONTINUATION,
  OP_TEXT,
  OP_BINARY,
  OP_CLOSE,
  OP_PING,
  OP_PONG,
]);

export function decodeWsFrames(buffer: Buffer): { frames: DecodedWsFrame[]; rest: Buffer } {
  const frames: DecodedWsFrame[] = [];
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const first = buffer[offset] ?? 0;
    const second = buffer[offset + 1];
    if (second === undefined) {
      break;
    }
    // RFC 6455 §5.2: RSV bits MUST be 0 unless an extension is negotiated
    if ((first & 0x70) !== 0) {
      throw requestError(400, "ws_protocol_error", "WebSocket RSV bits must be zero");
    }
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    if (!KNOWN_OPCODES.has(opcode)) {
      throw requestError(400, "ws_protocol_error", `Reserved WebSocket opcode 0x${opcode.toString(16)}`);
    }
    const isControl = (opcode & 0x08) !== 0;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    // RFC 6455 §5.5: Control frames MUST NOT be fragmented and MUST have payload <= 125 bytes
    if (isControl && (!fin || length > 125)) {
      throw requestError(400, "ws_protocol_error", "Control frames must be final and have payload <= 125 bytes");
    }
    let header = 2;
    if (length === 126) {
      if (offset + 4 > buffer.length) {
        break;
      }
      length = buffer.readUInt16BE(offset + 2);
      if (length < 126) {
        throw requestError(400, "ws_protocol_error", "Non-minimal length encoding (126 used for < 126 bytes)");
      }
      header = 4;
    } else if (length === 127) {
      if (offset + 10 > buffer.length) {
        break;
      }
      const high = buffer.readUInt32BE(offset + 2);
      const low = buffer.readUInt32BE(offset + 6);
      if (high !== 0 || low > MAX_WS_MESSAGE_BYTES) {
        throw requestError(413, "request_too_large", "WebSocket frame exceeds the 8 MiB limit");
      }
      if (high === 0 && low < 65536) {
        throw requestError(400, "ws_protocol_error", "Non-minimal length encoding (127 used for < 65536 bytes)");
      }
      length = low;
      header = 10;
    }
    if (length > MAX_WS_MESSAGE_BYTES) {
      throw requestError(413, "request_too_large", "WebSocket frame exceeds the 8 MiB limit");
    }
    const maskSize = masked ? 4 : 0;
    if (offset + header + maskSize + length > buffer.length) {
      break;
    }
    const mask = masked ? buffer.subarray(offset + header, offset + header + 4) : null;
    const raw = buffer.subarray(offset + header + maskSize, offset + header + maskSize + length);
    const payload = Buffer.from(raw);
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) {
        payload[i] = (payload[i] ?? 0) ^ (mask[i % 4] ?? 0);
      }
    }
    frames.push({ fin, opcode, masked, payload });
    offset += header + maskSize + length;
  }
  return { frames, rest: buffer.subarray(offset) };
}

export function failConnection(socket: Duplex, code: number, reason?: string): void {
  if (socket.destroyed) {
    return;
  }
  const reasonBuf = reason ? Buffer.from(reason, "utf8").subarray(0, 123) : Buffer.alloc(0);
  const payload = Buffer.concat([Buffer.from([(code >> 8) & 0xff, code & 0xff]), reasonBuf]);
  const frame = encodeWsFrame(OP_CLOSE, payload);
  const guard = setTimeout(() => socket.destroy(), 1_000);
  guard.unref();
  socket.end(frame, () => {
    clearTimeout(guard);
    socket.destroy();
  });
}

function writeHttpError(socket: Duplex, status: number, message: string, extraHeaders = ""): void {
  if (socket.destroyed) {
    return;
  }
  const body = JSON.stringify({ error: { message, type: "invalid_request_error" } });
  const payload = `HTTP/1.1 ${status} ${message}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n${extraHeaders}Connection: close\r\n\r\n${body}`;
  const guard = setTimeout(() => socket.destroy(), 1_000);
  guard.unref();
  socket.end(payload, () => {
    clearTimeout(guard);
    socket.destroy();
  });
}

async function readCapped(res: Response, limit = 65_536): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) {
    return "";
  }
  const decoder = new TextDecoder();
  let out = "";
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    total += value.length;
    if (total > limit) {
      await reader.cancel();
      break;
    }
    out += decoder.decode(value, { stream: true });
  }
  out += decoder.decode();
  return out;
}

const WS_DRAIN_TIMEOUT_MS = 10_000;

async function sendJson(socket: Duplex, value: unknown): Promise<void> {
  if (socket.destroyed) {
    return;
  }
  const frame = encodeWsText(JSON.stringify(value));
  const canWrite = socket.write(frame);
  if (!canWrite && !socket.destroyed) {
    await new Promise<void>((resolve) => {
      const onEvent = (): void => {
        clearTimeout(timer);
        socket.off("drain", onEvent);
        socket.off("close", onEvent);
        resolve();
      };
      const timer = setTimeout(() => {
        socket.destroy();
        onEvent();
      }, WS_DRAIN_TIMEOUT_MS);
      timer.unref();
      socket.once("drain", onEvent);
      socket.once("close", onEvent);
    });
  }
}

function parseSseBlock(block: string, streamId: string | undefined): Record<string, unknown> | null {
  const dataLines: string[] = [];
  for (const line of block.split("\n")) {
    if (line.startsWith("data:")) {
      dataLines.push(line.slice(5).trimStart());
    }
  }
  const data = dataLines.join("\n");
  if (!data || data === "[DONE]") {
    return null;
  }
  try {
    const parsed = JSON.parse(data) as Record<string, unknown>;
    if (streamId && parsed["stream_id"] === undefined) {
      parsed["stream_id"] = streamId;
    }
    return parsed;
  } catch {
    return { type: "error", stream_id: streamId, error: { message: data } };
  }
}

async function forwardCreate(
  socket: Duplex,
  options: ProxyOptions,
  message: Record<string, unknown>
): Promise<void> {
  const streamId = typeof message["stream_id"] === "string" ? message["stream_id"] : undefined;
  const target = relayTarget(options);
  if (!target) {
    await sendJson(socket, {
      type: "error",
      stream_id: streamId,
      status: 503,
      error: { code: "provider_not_configured", message: PROVIDER_NOT_CONFIGURED_MESSAGE },
    });
    return;
  }
  const generate = message["generate"];
  const candidate: Record<string, unknown> = { ...message };
  delete candidate["type"];
  delete candidate["stream_id"];
  delete candidate["generate"];
  candidate["stream"] = generate !== false;

  let body: Record<string, unknown>;
  try {
    body = validateResponsesBody(JSON.stringify(candidate));
  } catch (error) {
    await sendJson(socket, {
      type: "error",
      stream_id: streamId,
      status: 400,
      error: {
        code: "bad_request",
        message: error instanceof Error ? error.message : String(error),
      },
    });
    return;
  }
  const controller = new AbortController();
  const abort = (): void => controller.abort();
  socket.once("close", abort);
  let timedOut = false;
  const timeoutMs = options.nonStreamFetchTimeoutMs ?? DEFAULT_WS_FETCH_TIMEOUT_MS;
  const timeoutTimer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  try {
    const upstream = await fetch(target.responsesUrl, {
      method: "POST",
      headers: {
        Accept: "text/event-stream, application/json",
        "Accept-Encoding": "identity",
        Authorization: `Bearer ${target.credential}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      redirect: "manual",
      signal: controller.signal,
    });
    clearTimeout(timeoutTimer);
    if (upstream.status >= 300 && upstream.status < 400) {
      await upstream.body?.cancel();
      await sendJson(socket, {
        type: "error",
        stream_id: streamId,
        status: 502,
        error: { code: "unsafe_upstream_redirect", message: `${target.label} returned a redirect` },
      });
      return;
    }
    if (upstream.status === 404 || upstream.status === 405) {
      await upstream.body?.cancel();
      await sendJson(socket, {
        type: "error",
        stream_id: streamId,
        status: 502,
        error: {
          code: "dialect_not_supported",
          message: dialectNotSupportedMessage("/v1/responses", target.label),
        },
      });
      return;
    }
    const contentType = upstream.headers.get("content-type") ?? "";
    if (!contentType.includes("text/event-stream")) {
      const text = await readCapped(upstream, 1_048_576);
      try {
        const parsed = JSON.parse(text) as Record<string, unknown>;
        await sendJson(socket, {
          type: upstream.ok ? "response.completed" : "error",
          stream_id: streamId,
          status: upstream.status,
          response: parsed["response"] ?? parsed,
          error: parsed["error"],
        });
      } catch {
        await sendJson(socket, {
          type: "error",
          stream_id: streamId,
          status: upstream.status,
          error: { message: text.slice(0, 500) },
        });
      }
      return;
    }
    if (!upstream.body) {
      return;
    }
    const reader = upstream.body.getReader();
    const decoder = new TextDecoder();
    let carry = "";
    const MAX_SSE_CARRY_BYTES = 1_048_576;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        carry += decoder.decode();
        const tail = carry.replace(/\r\n/gu, "\n").replace(/\r/gu, "\n").trim();
        if (tail) {
          const event = parseSseBlock(tail, streamId);
          if (event) {
            await sendJson(socket, event);
          }
        }
        break;
      }
      carry += decoder.decode(value, { stream: true });
      if (carry.length > MAX_SSE_CARRY_BYTES) {
        controller.abort();
        await upstream.body.cancel();
        failConnection(socket, 1009, "upstream_frame_too_large");
        return;
      }
      const pendingCr = carry.endsWith("\r");
      const scan = (pendingCr ? carry.slice(0, -1) : carry)
        .replace(/\r\n/gu, "\n")
        .replace(/\r/gu, "\n");
      const parts = scan.split("\n\n");
      carry = (parts.pop() ?? "") + (pendingCr ? "\r" : "");
      for (const part of parts) {
        const event = parseSseBlock(part, streamId);
        if (event) {
          await sendJson(socket, event);
        }
      }
    }
  } catch (error) {
    clearTimeout(timeoutTimer);
    if (!socket.destroyed && (timedOut || !controller.signal.aborted)) {
      await sendJson(socket, {
        type: "error",
        stream_id: streamId,
        status: timedOut ? 504 : 502,
        error: timedOut
          ? {
              code: "upstream_timeout",
              message: `${target.label} did not respond within ${timeoutMs} ms`,
            }
          : {
              code: "bad_gateway",
              message: `${target.label} is unavailable: ${errorDetail(error)}`,
            },
      });
    }
  } finally {
    clearTimeout(timeoutTimer);
    socket.off("close", abort);
  }
}

const MAX_WS_SOCKETS = 32;
const WS_IDLE_TIMEOUT_MS = 300_000;
const MAX_WS_WRITE_BACKLOG_BYTES = 4 * 1024 * 1024;

async function handleSocket(
  socket: Duplex,
  head: Buffer,
  options: ProxyOptions
): Promise<void> {
  let queue: Buffer[] = head.length > 0 ? [head] : [];
  let queued = head.length;
  let fragmentOpcode = 0;
  let fragments: Buffer[] = [];
  let totalFragmentBytes = 0;
  let activeTurns = 0;

  if ("setTimeout" in socket && typeof (socket as { setTimeout?: unknown }).setTimeout === "function") {
    (socket as import("node:net").Socket).on("timeout", () => {
      failConnection(socket, 1001, "idle timeout");
    });
  }

  const armInactivityTimeout = (): void => {
    if ("setTimeout" in socket && typeof (socket as { setTimeout?: unknown }).setTimeout === "function") {
      (socket as import("node:net").Socket).setTimeout(WS_IDLE_TIMEOUT_MS);
    }
  };

  armInactivityTimeout();

  const onData = (chunk: Buffer): void => {
    armInactivityTimeout();
    if ("writableLength" in socket && typeof (socket as { writableLength?: number }).writableLength === "number") {
      if ((socket as { writableLength: number }).writableLength > MAX_WS_WRITE_BACKLOG_BYTES) {
        failConnection(socket, 1008);
        return;
      }
    }
    queue.push(chunk);
    queued += chunk.length;
    if (queued + totalFragmentBytes > MAX_WS_MESSAGE_BYTES + 16) {
      failConnection(socket, 1009);
      return;
    }
    try {
      const first = queue[0];
      const buf = queue.length === 1 && first ? first : Buffer.concat(queue, queued);
      const { frames, rest } = decodeWsFrames(buf);
      queue = rest.length > 0 ? [rest] : [];
      queued = rest.length;
      for (const frame of frames) {
        // RFC 6455 §5.1: Clients MUST mask all frames sent to server
        if (!frame.masked) {
          failConnection(socket, 1002);
          return;
        }

        // Control frames
        if (frame.opcode === OP_CLOSE) {
          let code = 1000;
          if (frame.payload.length >= 2) {
            code = frame.payload.readUInt16BE(0);
            if (
              code < 1000 ||
              code === 1004 ||
              code === 1005 ||
              code === 1006 ||
              code === 1015 ||
              (code >= 1016 && code <= 2999) ||
              code >= 5000
            ) {
              failConnection(socket, 1002);
              return;
            }
            if (frame.payload.length > 2) {
              try {
                new TextDecoder("utf-8", { fatal: true }).decode(frame.payload.subarray(2));
              } catch {
                failConnection(socket, 1007);
                return;
              }
            }
          } else if (frame.payload.length === 1) {
            failConnection(socket, 1002);
            return;
          }
          failConnection(socket, code);
          return;
        }
        if (frame.opcode === OP_PING) {
          if (!socket.write(encodeWsFrame(OP_PONG, frame.payload))) {
            socket.pause();
            socket.once("drain", () => socket.resume());
          }
          continue;
        }
        if (frame.opcode === OP_PONG) {
          continue;
        }

        // Handle continuation frames (opcode 0x0)
        let completePayload: Buffer | null = null;
        if (frame.opcode === OP_CONTINUATION) {
          if (fragmentOpcode === 0) {
            failConnection(socket, 1002);
            return;
          }
          if (queued + totalFragmentBytes + frame.payload.length > MAX_WS_MESSAGE_BYTES) {
            failConnection(socket, 1009);
            return;
          }
          fragments.push(frame.payload);
          totalFragmentBytes += frame.payload.length;
          if (frame.fin) {
            completePayload = Buffer.concat(fragments);
            fragments = [];
            totalFragmentBytes = 0;
            fragmentOpcode = 0;
          }
        } else if (frame.opcode === OP_TEXT) {
          if (fragmentOpcode !== 0) {
            failConnection(socket, 1002);
            return;
          }
          if (frame.fin) {
            completePayload = frame.payload;
          } else {
            if (queued + frame.payload.length > MAX_WS_MESSAGE_BYTES) {
              failConnection(socket, 1009);
              return;
            }
            fragmentOpcode = frame.opcode;
            fragments = [frame.payload];
            totalFragmentBytes = frame.payload.length;
          }
        } else if (frame.opcode === OP_BINARY) {
          failConnection(socket, 1003);
          return;
        } else {
          failConnection(socket, 1002);
          return;
        }

        if (completePayload === null) {
          continue;
        }

        let text: string;
        try {
          text = new TextDecoder("utf-8", { fatal: true }).decode(completePayload);
        } catch {
          failConnection(socket, 1007);
          return;
        }

        let parsed: Record<string, unknown>;
        try {
          parsed = JSON.parse(text) as Record<string, unknown>;
        } catch {
          void sendJson(socket, { type: "error", error: { message: "WebSocket text frames must be JSON" } }).catch(
            () => socket.destroy()
          );
          continue;
        }
        if (parsed["type"] === "response.create") {
          if (activeTurns >= MAX_CONCURRENT_SOCKET_TURNS) {
            void sendJson(socket, {
              type: "error",
              stream_id: typeof parsed["stream_id"] === "string" ? parsed["stream_id"] : undefined,
              status: 429,
              error: { code: "rate_limit_exceeded", message: "Concurrent request limit exceeded on WebSocket connection" },
            }).catch(() => socket.destroy());
            continue;
          }
          activeTurns += 1;
          void (async () => {
            try {
              await forwardCreate(socket, options, parsed);
            } catch {
              void sendJson(socket, {
                type: "error",
                status: 500,
                error: { message: "Internal proxy error" },
              }).catch(() => socket.destroy());
            } finally {
              activeTurns = Math.max(0, activeTurns - 1);
            }
          })();
          continue;
        }
        void sendJson(socket, {
          type: "error",
          error: { message: `Unsupported WebSocket event type: ${String(parsed["type"] ?? "")}` },
        }).catch(() => socket.destroy());
      }
    } catch (error) {
      const isOversize =
        error instanceof Error &&
        (error.message.includes("too large") || error.message.includes("413"));
      failConnection(socket, isOversize ? 1009 : 1002);
    }
  };
  socket.on("data", onData);
  socket.on("error", () => socket.destroy());
  socket.on("end", () => socket.destroy());
  if (queue.length > 0) {
    onData(Buffer.alloc(0));
  }
}

export function attachResponsesWebSocket(server: Server, options: ProxyOptions): void {
  const sockets = new Set<Duplex>();
  const innerClose = server.close.bind(server);
  server.close = ((callback?: (err?: Error) => void) => {
    for (const socket of sockets) {
      socket.destroy();
    }
    sockets.clear();
    return innerClose(callback);
  }) as typeof server.close;

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    socket.on("error", () => socket.destroy());

    if (!isLoopbackHost(firstHeaderValue(req.headers["host"]))) {
      writeHttpError(socket, 403, "Host header must be a loopback address (127.0.0.1, localhost, or [::1])");
      return;
    }

    if (!isAllowedOrigin(firstHeaderValue(req.headers["origin"]))) {
      writeHttpError(socket, 403, "Cross-origin WebSocket upgrades from non-loopback origins are forbidden");
      return;
    }

    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname !== "/v1/responses") {
      writeHttpError(socket, 404, `Not found: UPGRADE ${url.pathname}`);
      return;
    }
    if (
      !isAuthorized(
        firstHeaderValue(req.headers["authorization"]),
        firstHeaderValue(req.headers["x-api-key"]),
        req.socket.remoteAddress,
        options
      ) ||
      !isLoopbackIp(req.socket.remoteAddress)
    ) {
      writeHttpError(socket, 401, "Incorrect API key or missing Bearer / x-api-key on loopback");
      return;
    }
    if (req.method !== "GET") {
      writeHttpError(socket, 405, "WebSocket upgrade requires GET");
      return;
    }
    const version = firstHeaderValue(req.headers["sec-websocket-version"]);
    if (version !== "13") {
      writeHttpError(socket, 426, "Upgrade Required", "Sec-WebSocket-Version: 13\r\n");
      return;
    }
    const key = firstHeaderValue(req.headers["sec-websocket-key"]);
    const upgrade = firstHeaderValue(req.headers["upgrade"])?.toLowerCase();
    if (!key || upgrade !== "websocket" || !/^[A-Za-z0-9+/]{22}==$/u.test(key)) {
      writeHttpError(socket, 400, "WebSocket upgrade requires a valid 16-byte base64 Sec-WebSocket-Key");
      return;
    }
    if (sockets.size >= MAX_WS_SOCKETS) {
      writeHttpError(socket, 503, "Maximum WebSocket connections reached");
      return;
    }
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.write(
      [
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Accept: ${websocketAcceptKey(key)}`,
        "\r\n",
      ].join("\r\n")
    );
    void handleSocket(socket, head, options);
  });
}

