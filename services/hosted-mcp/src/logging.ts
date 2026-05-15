import { redact } from "./redaction.js";

export function logInfo(message: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ severity: "INFO", message, ...(redact(fields) as Record<string, unknown>) }));
}

export function logWarn(message: string, fields: Record<string, unknown> = {}): void {
  console.warn(JSON.stringify({ severity: "WARNING", message, ...(redact(fields) as Record<string, unknown>) }));
}

export function logError(message: string, fields: Record<string, unknown> = {}): void {
  console.error(JSON.stringify({ severity: "ERROR", message, ...(redact(fields) as Record<string, unknown>) }));
}
