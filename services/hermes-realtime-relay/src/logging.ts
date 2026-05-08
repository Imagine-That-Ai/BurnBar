import { createHash } from "node:crypto";

export interface LogFields {
  [key: string]: string | number | boolean | undefined;
}

export function uidHash(uid: string): string {
  return createHash("sha256").update(uid).digest("hex").slice(0, 16);
}

export function logEvent(event: string, fields: LogFields = {}): void {
  console.log(JSON.stringify({ severity: "INFO", event, ...fields }));
}

export function logWarning(event: string, fields: LogFields = {}): void {
  console.warn(JSON.stringify({ severity: "WARNING", event, ...fields }));
}

export function logError(event: string, error: unknown, fields: LogFields = {}): void {
  const message = error instanceof Error ? error.message : "unknown error";
  console.error(JSON.stringify({ severity: "ERROR", event, message, ...fields }));
}
