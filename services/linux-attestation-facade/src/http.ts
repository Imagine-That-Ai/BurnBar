import type { IncomingMessage, ServerResponse } from "node:http";
import { PublicError, publicError } from "./errors.js";
import { parseJsonBuffer } from "./validation.js";

export async function readBody(request: IncomingMessage, maxBytes: number): Promise<Buffer> {
  const declared = request.headers["content-length"];
  if (declared !== undefined) {
    if (!/^(0|[1-9][0-9]*)$/u.test(declared) || !Number.isSafeInteger(Number(declared))) {
      throw new PublicError(400, "bad_request", "Content-Length is invalid");
    }
    if (Number(declared) > maxBytes) throw new PublicError(413, "payload_too_large", "Request payload is too large");
  }
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const value of request) {
    const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value as Uint8Array);
    size += chunk.byteLength;
    if (size > maxBytes) throw new PublicError(413, "payload_too_large", "Request payload is too large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export async function readExactBody(request: IncomingMessage, expectedBytes: number, hardLimit: number): Promise<Buffer> {
  if (!Number.isSafeInteger(expectedBytes) || expectedBytes <= 0 || expectedBytes > hardLimit) {
    throw new PublicError(413, "payload_too_large", "Request payload is too large");
  }
  const declared = request.headers["content-length"];
  if (declared !== undefined && Number(declared) !== expectedBytes) {
    throw new PublicError(400, "bad_request", "Request payload size does not match the upload declaration");
  }
  const bytes = await readBody(request, expectedBytes);
  if (bytes.byteLength !== expectedBytes) {
    throw new PublicError(400, "bad_request", "Request payload size does not match the upload declaration");
  }
  return bytes;
}

export async function readJson(request: IncomingMessage, maxBytes: number): Promise<unknown> {
  if (request.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    throw new PublicError(400, "bad_request", "Content-Type must be application/json");
  }
  return parseJsonBuffer(await readBody(request, maxBytes), "request body");
}

export function bearerToken(request: IncomingMessage): string {
  const authorization = request.headers.authorization;
  if (authorization === undefined || !authorization.startsWith("Bearer ") || authorization.length <= 7 || authorization.includes(",")) {
    throw new PublicError(401, "unauthorized", "Authentication is required");
  }
  return authorization.slice(7);
}

export function json(response: ServerResponse, status: number, body: unknown): void {
  const bytes = Buffer.from(JSON.stringify(body), "utf8");
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": String(bytes.byteLength), "cache-control": "no-store", "x-content-type-options": "nosniff" });
  response.end(bytes);
}

export function empty(response: ServerResponse, status = 204): void {
  response.writeHead(status, { "cache-control": "no-store" });
  response.end();
}

export function handleError(response: ServerResponse, error: unknown): void {
  const safe = publicError(error);
  json(response, safe.status, { error: { code: safe.code, message: safe.publicMessage, retryable: safe.retryable } });
}
