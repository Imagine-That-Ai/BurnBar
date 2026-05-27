import { createHmac, timingSafeEqual } from "node:crypto";
import { HttpError } from "./errors.js";

const CURSOR_SECRET = () => process.env.MCP_CURSOR_HMAC_SECRET ?? process.env.MCP_TOKEN_HMAC_SECRET ?? "dev-cursor-secret";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseCursorPayload(raw: unknown): CursorPayload {
  if (!isRecord(raw)) {
    throw new HttpError(400, "Malformed cursor.", "malformed_cursor");
  }
  const uid = raw.uid;
  const tool = raw.tool;
  const offset = raw.offset;
  const exp = raw.exp;
  const resourceUri = raw.resourceUri;
  if (
    typeof uid !== "string"
    || typeof tool !== "string"
    || typeof offset !== "number"
    || typeof exp !== "number"
    || (resourceUri !== undefined && typeof resourceUri !== "string")
  ) {
    throw new HttpError(400, "Malformed cursor.", "malformed_cursor");
  }
  return {
    uid,
    tool,
    offset,
    exp,
    resourceUri,
  };
}

export interface CursorPayload {
  uid: string;
  tool: string;
  offset: number;
  resourceUri?: string;
  exp: number;
}

export function signCursor(payload: CursorPayload): string {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const sig = createHmac("sha256", CURSOR_SECRET()).update(body).digest("base64url");
  return `${body}.${sig}`;
}

export function verifyCursor(cursor: string, uid: string, tool: string): CursorPayload {
  const [body, sig] = cursor.split(".");
  if (!body || !sig) throw new HttpError(400, "Malformed cursor.", "malformed_cursor");
  const expected = createHmac("sha256", CURSOR_SECRET()).update(body).digest();
  const actual = Buffer.from(sig, "base64url");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new HttpError(400, "Cursor signature is invalid.", "cursor_tampered");
  }
  const payload = parseCursorPayload(JSON.parse(Buffer.from(body, "base64url").toString("utf8")));
  if (payload.uid !== uid || payload.tool !== tool || payload.exp <= Date.now()) {
    throw new HttpError(400, "Cursor is expired or does not match this request.", "cursor_scope_mismatch");
  }
  return payload;
}
