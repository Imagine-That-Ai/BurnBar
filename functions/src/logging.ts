/**
 * Structured Cloud Functions logging with trace correlation.
 */

import { randomUUID } from "node:crypto";

export interface LogFields {
  event: string;
  trace_id?: string;
  session_id?: string;
  user_id_hash?: string;
  [key: string]: string | number | boolean | undefined;
}

export function logInfo(fields: LogFields): void {
  const payload = {
    severity: "INFO",
    trace_id: fields.trace_id ?? randomUUID(),
    ...fields,
  };
  console.log(JSON.stringify(payload));
}

export function logError(fields: LogFields & { error?: string }): void {
  const payload = {
    severity: "ERROR",
    trace_id: fields.trace_id ?? randomUUID(),
    ...fields,
  };
  console.error(JSON.stringify(payload));
}
