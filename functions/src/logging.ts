/**
 * Structured Cloud Functions logging with trace correlation.
 */

import { randomUUID } from "node:crypto";
import type { CallableRequest } from "firebase-functions/v2/https";

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

export function logWarn(fields: LogFields): void {
  const payload = {
    severity: "WARNING",
    trace_id: fields.trace_id ?? randomUUID(),
    ...fields,
  };
  console.warn(JSON.stringify(payload));
}

export function traceIdFromCallableRequest(request: { rawRequest?: { headers?: Record<string, unknown> } }): string {
  const headers = request.rawRequest?.headers;
  const incoming = headers?.["x-cloud-trace-context"] ?? headers?.["x-trace-id"];
  if (typeof incoming === "string" && incoming.trim().length > 0) {
    return incoming.split("/")[0]?.trim() || randomUUID();
  }
  return randomUUID();
}

export function logCallableStart(name: string, traceId: string, uid?: string): void {
  logInfo({
    event: "callable_start",
    callable: name,
    trace_id: traceId,
    user_id_hash: uid?.slice(0, 8),
  });
}

export function logCallableSuccess(name: string, traceId: string, uid?: string): void {
  logInfo({
    event: "callable_success",
    callable: name,
    trace_id: traceId,
    user_id_hash: uid?.slice(0, 8),
  });
}

export function logCallableFailure(name: string, traceId: string, error: unknown, uid?: string): void {
  logError({
    event: "callable_error",
    callable: name,
    trace_id: traceId,
    user_id_hash: uid?.slice(0, 8),
    error: String(error),
  });
}

export async function withCallableLogging<T>(
  name: string,
  request: { rawRequest?: { headers?: Record<string, unknown> } },
  uid: string | undefined,
  handler: (traceId: string) => Promise<T>,
): Promise<T> {
  const traceId = traceIdFromCallableRequest(request);
  logCallableStart(name, traceId, uid);
  try {
    const result = await handler(traceId);
    logCallableSuccess(name, traceId, uid);
    return result;
  } catch (error) {
    logCallableFailure(name, traceId, error, uid);
    throw error;
  }
}

/**
 * Wraps a callable handler with start/success/error structured logs.
 * Prefer migrating exports from raw `onCall` to `onCallWithLogging` for SLO probes.
 */
export function onCallWithLogging<T, R>(
  name: string,
  handler: (request: { auth?: { uid?: string }; rawRequest?: { headers?: Record<string, unknown> } }) => Promise<R>,
): (request: { auth?: { uid?: string }; rawRequest?: { headers?: Record<string, unknown> } }) => Promise<R> {
  return async (request) =>
    withCallableLogging(name, request, request.auth?.uid, async () => handler(request));
}

/**
 * Wraps a v2 `onCall` handler with callable_start / callable_success / callable_error logs.
 * Use as the second argument to `onCall(options, wrapCallableHandler("name", handler))`.
 */
export function wrapCallableHandler<Data, R>(
  name: string,
  handler: (request: CallableRequest<Data>) => Promise<R>,
): (request: CallableRequest<Data>) => Promise<R> {
  return async (request: CallableRequest<Data>) => {
    const uid = request.auth?.uid;
    return withCallableLogging(name, request, uid, () => handler(request));
  };
}
