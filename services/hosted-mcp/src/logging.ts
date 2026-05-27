import { redact } from "./redaction.js";

export function logInfo(message: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ severity: "INFO", message, ...redactedFields(fields) }));
}

export function logWarn(message: string, fields: Record<string, unknown> = {}): void {
  console.warn(JSON.stringify({ severity: "WARNING", message, ...redactedFields(fields) }));
}

export function logError(message: string, fields: Record<string, unknown> = {}): void {
  console.error(JSON.stringify({ severity: "ERROR", message, ...redactedFields(fields) }));
}

function redactedFields(fields: Record<string, unknown>): Record<string, unknown> {
  const redacted = redact(fields);
  return typeof redacted === "object" && redacted !== null && !Array.isArray(redacted)
    ? Object.fromEntries(Object.entries(redacted))
    : {};
}
