import { createHmac, timingSafeEqual } from "node:crypto";
import { HttpError } from "./errors.js";

const CURSOR_SECRET = () => process.env.MCP_CURSOR_HMAC_SECRET ?? process.env.MCP_TOKEN_HMAC_SECRET ?? "dev-cursor-secret";

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
  const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as CursorPayload;
  if (payload.uid !== uid || payload.tool !== tool || payload.exp <= Date.now()) {
    throw new HttpError(400, "Cursor is expired or does not match this request.", "cursor_scope_mismatch");
  }
  return payload;
}
