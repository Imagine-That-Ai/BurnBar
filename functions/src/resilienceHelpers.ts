/**
 * Thin helpers for wrapping external calls with cockatiel policies.
 * @see resilience.ts
 */

import {
  externalApiPolicy,
  firestorePolicy,
  pushPolicy,
  quotaPolicy,
  stripePolicy,
  withResilience,
} from "./resilience.js";

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

export async function quotaWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(quotaPolicy, `quota:${label}`, fn);
}

/** Outbound HTTP from Functions (quota runner, insights, benchmarks). */
export async function resilientFetch(label: string, url: string | URL, init?: RequestInit): Promise<Response> {
  return externalApiWithResilience(label, () => fetch(url, init));
}
