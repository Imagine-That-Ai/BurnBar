/**
 * Thin helpers for wrapping external calls with cockatiel policies.
 * @see resilience.ts
 */

import {
  externalApiPolicy,
  firestorePolicy,
  pushPolicy,
  stripePolicy,
  withResilience,
} from "./resilience.js";
import { assertOutboundFetchTarget } from "./ssrfGuard.js";

interface ResilientFetchOptions {
  /** Permit private/link-local/metadata hosts (e.g. the GCP metadata identity fetch). */
  allowPrivateHosts?: boolean;
}

export async function stripeWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(stripePolicy, `stripe:${label}`, fn);
}

export async function pushWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(pushPolicy, `push:${label}`, fn);
}

export async function firestoreWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(firestorePolicy, `firestore:${label}`, fn);
}

export async function externalApiWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(externalApiPolicy, `external:${label}`, fn);
}

/** Outbound HTTP from Functions (quota runner, insights, benchmarks). */
export async function resilientFetch(
  label: string,
  url: string | URL,
  init?: RequestInit,
  options?: ResilientFetchOptions,
): Promise<Response> {
  // L5: defense-in-depth SSRF guard. Blocks cloud metadata + private/link-local
  // hosts unless explicitly opted in (the GCP metadata identity fetch).
  assertOutboundFetchTarget(url, options?.allowPrivateHosts ?? false);
  return externalApiWithResilience(label, () => fetch(url, init));
}
