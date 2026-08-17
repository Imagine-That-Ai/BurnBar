/**
 * Attested callable wrapper for high-risk grant actions.
 *
 * Mirrors the Mac client sequence (ComputerUseSecurityCallableClient):
 *   bindAppCheckAttestation -> getIdToken(true) -> issueHighRiskActionNonce
 *   -> target callable with { ...payload, nonce }
 *
 * The bind writes an `obb_app_check` custom claim scoped to the App Check app
 * id; the forced ID-token refresh propagates that claim; the single-use nonce
 * adds replay resistance. When the nonce mint is rejected because another
 * signed-in platform overwrote the binding, we rebind, refresh, remint, and
 * retry once (same rebound logic as the Mac client).
 */
import { httpsCallable } from "firebase/functions";
import { auth, functions } from "./firebaseClient";

/** Normalizes `functions/not-found` -> `not-found` so callers can map codes. */
export function callableErrorCode(err: unknown): string {
  const code = (err as { code?: unknown } | null | undefined)?.code;
  if (typeof code !== "string") return "";
  return code.startsWith("functions/") ? code.slice("functions/".length) : code;
}

function errorMessage(err: unknown): string {
  const message = (err as { message?: unknown } | null | undefined)?.message;
  return typeof message === "string" ? message : "";
}

/**
 * True when the error is an App Check binding conflict: permission-denied or
 * failed-precondition from a callable whose message names the attestation
 * binding. Matches the Mac `isAppCheckBindingConflictError` gate.
 */
export function isAppCheckBindingConflictError(err: unknown): boolean {
  const code = callableErrorCode(err);
  if (code !== "permission-denied" && code !== "failed-precondition") return false;
  const message = errorMessage(err);
  return message.includes("App Check") || message.includes("bindAppCheckAttestation");
}

async function bindAppCheckAttestation(): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error("Sign in before binding App Check attestation.");
  await httpsCallable(functions, "bindAppCheckAttestation")({});
  await user.getIdToken(true);
}

async function issueHighRiskActionNonce(): Promise<string> {
  const result = await httpsCallable(functions, "issueHighRiskActionNonce")({});
  const data = result.data as { nonce?: unknown };
  if (typeof data?.nonce !== "string" || data.nonce.length === 0) {
    throw new Error("Could not obtain a high-risk action nonce.");
  }
  return data.nonce;
}

async function reboundHighRiskActionNonce(afterBindingConflict: unknown): Promise<string> {
  if (!isAppCheckBindingConflictError(afterBindingConflict)) throw afterBindingConflict;
  await bindAppCheckAttestation();
  return issueHighRiskActionNonce();
}

/**
 * Invokes a high-risk callable after the full attestation sequence:
 * bind -> refresh ID token -> mint nonce (with one rebind/remint on an App
 * Check binding conflict) -> call with `{ ...payload, nonce }`.
 */
export async function attestedCallable<Response = unknown>(
  callableName: string,
  payload: Record<string, unknown> = {}
): Promise<Response> {
  if (!auth.currentUser) throw new Error("Sign in before completing this action.");
  await bindAppCheckAttestation();
  let nonce: string;
  try {
    nonce = await issueHighRiskActionNonce();
  } catch (err) {
    nonce = await reboundHighRiskActionNonce(err);
  }
  const result = await httpsCallable(functions, callableName)({ ...payload, nonce });
  return result.data as Response;
}
