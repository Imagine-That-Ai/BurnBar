/**
 * Hardened outbound HTTP client for user/config-supplied URLs.
 *
 * SECURITY (L5): `assertOutboundFetchTarget` is the synchronous string gate, but a
 * hostname that passes the string check can still resolve to a private/metadata IP
 * (classic DNS-rebinding / TOCTOU). Per the OWASP SSRF Prevention Cheat Sheet, the
 * only robust defense is to resolve DNS once and connect to *that exact validated
 * address*. This module provides an undici `Agent` whose `connect.lookup` hook
 * resolves the name, rejects the connection unless the resolved IP passes the
 * strict public-unicast allowlist, and pins the socket to the validated address —
 * so the name cannot rebind to a private IP between the check and the connect.
 * Redirects are disabled (`maxRedirections: 0`) so a 30x cannot bounce the request
 * to an unchecked internal host.
 *
 * This is intentionally NOT wired into the legacy provider quota path (which only
 * ever fetches fixed public hosts and the sanctioned GCP metadata endpoint via
 * `allowPrivateHosts: true`); it is the client a future user-URL feature must use.
 */

import type { LookupAddress, LookupOptions } from "node:dns";
import { lookup as dnsLookup } from "node:dns";
import { Agent } from "undici";

import {
  SsrfBlockedError,
  assertOutboundFetchTarget,
  assertOutboundFetchTargetResolved,
  isPublicUnicastAddress,
} from "./ssrfGuard.js";

type LookupCallback = (err: NodeJS.ErrnoException | null, address: string | LookupAddress[], family?: number) => void;

/**
 * DNS lookup wrapper that resolves a hostname and errors unless EVERY resolved
 * address is a public unicast IP. Returning only validated addresses to undici
 * pins the connection to a checked IP, closing the rebind window between the
 * string check and the socket connect.
 */
function pinnedLookup(hostname: string, options: LookupOptions, callback: LookupCallback): void {
  // `all: true` so undici receives the full validated address set (and so we
  // validate every address a name resolves to, not just the first).
  dnsLookup(hostname, { ...options, all: true }, (err, addresses) => {
    if (err) {
      callback(err, []);
      return;
    }
    const resolved = addresses as LookupAddress[];
    if (resolved.length === 0) {
      callback(new SsrfBlockedError(hostname), []);
      return;
    }
    for (const { address } of resolved) {
      if (!isPublicUnicastAddress(address)) {
        callback(new SsrfBlockedError(`${hostname} -> ${address}`), []);
        return;
      }
    }
    callback(null, resolved);
  });
}

let cachedAgent: Agent | undefined;

/**
 * The singleton DNS-pinning, redirect-disabled outbound dispatcher. Use this as
 * the `dispatcher` for any `fetch` of a user/config-supplied URL.
 */
export function ssrfHardenedAgent(): Agent {
  cachedAgent ??= new Agent({
    connect: { lookup: pinnedLookup },
    maxRedirections: 0,
  });
  return cachedAgent;
}

/**
 * `fetch` for user/config-supplied URLs that layers all three OWASP defenses:
 *  1. the synchronous SSRF string/canonicalization gate ({@link assertOutboundFetchTarget}),
 *  2. an application-layer resolved-IP gate ({@link assertOutboundFetchTargetResolved}),
 *     which resolves DNS and rejects if any address is private/metadata, then
 *  3. dispatch through the DNS-pinning, redirect-disabled agent so a hostname that
 *     rebinds between the gate and the connect (TOCTOU), or a 30x redirect, still
 *     cannot reach an internal/metadata endpoint — the socket binds only to a
 *     freshly-revalidated public-unicast address.
 *
 * Unlike `resilientFetch`, this path never exposes an `allowPrivateHosts` escape:
 * the sanctioned GCP metadata fetch stays on its own dedicated path.
 */
export async function ssrfHardenedFetch(url: string | URL, init?: RequestInit): Promise<Response> {
  assertOutboundFetchTarget(url);
  await assertOutboundFetchTargetResolved(url);
  return fetch(url, {
    ...init,
    redirect: "error",
    // undici reads the dispatcher off the init bag in Node's global fetch.
    dispatcher: ssrfHardenedAgent(),
  } as RequestInit & { dispatcher: Agent });
}
