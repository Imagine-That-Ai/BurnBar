/**
 * SSRF guard for server-side outbound HTTP.
 *
 * SECURITY (L5): today every `resilientFetch`/`providerFetch` target is a fixed
 * public provider host or a config-supplied URL, so there is no request-body
 * controlled host reaching a server fetch. This guard is defense-in-depth so that
 * the day a feature DOES accept a user-supplied URL (remote-MCP discovery,
 * webhooks, link unfurling), it cannot be pointed at cloud metadata or the
 * internal network. The highest-value SSRF target is the cloud metadata service
 * (credential theft), so that is blocked hardest.
 *
 * Loopback is intentionally allowed so the local emulator / dev quota runner and
 * localhost-configured endpoints keep working; the metadata identity fetch opts in
 * explicitly via `allowPrivateHosts`.
 *
 * SOTA hardening (2026), per the OWASP SSRF Prevention Cheat Sheet:
 *  1. CANONICALIZE the host before any range check — IPv4 alternative encodings
 *     (decimal `2130706433`, hex `0x7f000001`, octal, dword, short-form) AND
 *     IPv4-mapped IPv6 (`::ffff:127.0.0.1`, `::ffff:7f00:1`) all normalize to a
 *     single dotted-decimal so they are treated identically to `127.0.0.1`.
 *  2. REJECT every host that is (or, for {@link assertOutboundFetchTargetResolved},
 *     resolves to) a non-public-unicast address: loopback `127/8` + `::1`,
 *     RFC1918 `10/8` / `172.16/12` / `192.168/16`, CGNAT `100.64/10`,
 *     link-local `169.254/16` (incl. GCP metadata `169.254.169.254`) + `fe80::/10`,
 *     "this network" `0/8`, ULA `fc00::/7`, multicast (`224/4`, `ff00::/8`),
 *     reserved `240/4`, broadcast, unspecified `::`/`0.0.0.0`, and the metadata
 *     hostnames (`metadata.google.internal`, etc.).
 *  3. DNS rebinding / TOCTOU: a hostname string check alone cannot stop a name
 *     that resolves to a private IP. User-supplied URL fetches must additionally
 *     go through the DNS-pinning client in `ssrfAgent.ts` (or call
 *     {@link assertOutboundFetchTargetResolved} and connect only to a checked IP),
 *     which resolves once, validates the resolved address, and disables redirects.
 *
 * `assertOutboundFetchTarget` stays the synchronous string/canonicalization gate.
 */

import { lookup } from "node:dns/promises";

const BLOCKED_HOSTNAMES = new Set(["metadata.google.internal", "metadata", "metadata.goog"]);

function isBlockedIpv4(host: string): boolean {
  // `host` is canonical dotted-decimal "a.b.c.d".
  const octets = host.split(".").map((part) => Number.parseInt(part, 10));
  if (octets.length !== 4 || octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return true; // not parseable as a clean IPv4 -> fail closed
  }
  const [a, b] = octets;
  if (a === 0) return true; // 0.0.0.0/8 "this network" / unspecified
  if (a === 127) return true; // 127.0.0.0/8 loopback
  if (a === 10) return true; // 10.0.0.0/8 RFC1918
  if (a === 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12 RFC1918
  if (a === 192 && b === 168) return true; // 192.168.0.0/16 RFC1918
  if (a === 169 && b === 254) return true; // 169.254.0.0/16 link-local (incl. metadata)
  if (a === 100 && b >= 64 && b <= 127) return true; // 100.64.0.0/10 CGNAT (RFC6598)
  if (a >= 224 && a <= 239) return true; // 224.0.0.0/4 multicast
  if (a >= 240) return true; // 240.0.0.0/4 reserved + 255.255.255.255 broadcast
  return false;
}

/** True only for loopback `127.0.0.0/8` (the sanctioned local-dev exception). */
function isLoopbackIpv4(host: string): boolean {
  return /^127\./.test(host);
}

function dottedIpv4FromInteger(value: number): string {
  const a = Math.floor(value / 2 ** 24) % 256;
  const b = Math.floor(value / 2 ** 16) % 256;
  const c = Math.floor(value / 2 ** 8) % 256;
  const d = value % 256;
  return `${a}.${b}.${c}.${d}`;
}

/**
 * Canonicalize an IPv6 literal that actually carries an IPv4 address
 * (`::ffff:127.0.0.1`, `::ffff:7f00:1`, the deprecated `::127.0.0.1`) into the
 * embedded dotted-decimal IPv4 so IPv4 range rules apply. Returns `null` when the
 * literal is a genuine IPv6 address.
 */
function ipv4FromMappedIpv6(host: string): string | null {
  const h = host.replace(/^\[/, "").replace(/\]$/, "").toLowerCase();
  // Embedded dotted-decimal form: ::ffff:127.0.0.1 or ::127.0.0.1
  const dotted = /^(?:::ffff:|::)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(h);
  if (dotted) return normalizeIpv4(dotted[1]);
  // Hextet form of the mapped range: ::ffff:7f00:1
  const hex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(h);
  if (hex) {
    const high = Number.parseInt(hex[1], 16);
    const low = Number.parseInt(hex[2], 16);
    if (Number.isNaN(high) || Number.isNaN(low)) return null;
    const value = high * 0x10000 + low;
    return dottedIpv4FromInteger(value);
  }
  return null;
}

function isBlockedIpv6(host: string): boolean {
  const h = host.replace(/^\[/, "").replace(/\]$/, "").toLowerCase();
  if (h === "::" || h === "::0") return true; // unspecified
  if (h === "::1") return true; // loopback
  // Link-local fe80::/10 covers fe80:: .. febf::
  if (/^fe[89ab][0-9a-f]?:/.test(h)) return true;
  if (h.startsWith("fc") || h.startsWith("fd")) return true; // unique local fc00::/7
  if (h.startsWith("ff")) return true; // multicast ff00::/8
  return false;
}

function parseIpv4NumericPart(part: string): number | null {
  let value: number;
  if (/^0x[0-9a-f]+$/i.test(part)) {
    value = Number.parseInt(part, 16);
  } else if (/^0[0-7]+$/.test(part) && part.length > 1) {
    value = Number.parseInt(part, 8);
  } else if (/^\d+$/.test(part)) {
    value = Number.parseInt(part, 10);
  } else {
    return null;
  }
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

/**
 * Normalize IPv4 literals from dotted-decimal, decimal integer, hexadecimal,
 * octal, and legacy short-form encodings to canonical dotted-decimal. Returns
 * `null` when the input is not a valid IPv4 literal.
 */
export function normalizeIpv4(host: string): string | null {
  const parts = host.split(".");
  if (parts.length < 1 || parts.length > 4 || parts.some((part) => part.length === 0)) {
    return null;
  }

  const numericParts = parts.map(parseIpv4NumericPart);
  if (numericParts.some((part) => part === null)) return null;
  const nums = numericParts as number[];

  let value: number;
  switch (nums.length) {
    case 1:
      if (nums[0] > 0xffffffff) return null;
      value = nums[0];
      break;
    case 2:
      if (nums[0] > 0xff || nums[1] > 0xffffff) return null;
      value = nums[0] * 2 ** 24 + nums[1];
      break;
    case 3:
      if (nums[0] > 0xff || nums[1] > 0xff || nums[2] > 0xffff) return null;
      value = nums[0] * 2 ** 24 + nums[1] * 2 ** 16 + nums[2];
      break;
    case 4:
      if (nums.some((part) => part > 0xff)) return null;
      value = nums[0] * 2 ** 24 + nums[1] * 2 ** 16 + nums[2] * 2 ** 8 + nums[3];
      break;
    default:
      return null;
  }

  return dottedIpv4FromInteger(value);
}

/** Verdict for a single canonicalized host literal. */
type HostVerdict = "loopback" | "blocked" | "public";

/**
 * Canonicalize `host` (an IP literal or hostname) and classify it. IPv4 in any
 * encoding and IPv4-mapped IPv6 are folded to dotted-decimal first; genuine IPv6
 * is checked against the IPv6 block list. Non-IP hostnames return "public" unless
 * they are a known metadata name (callers still resolve DNS for rebinding).
 */
function classifyHostLiteral(host: string): HostVerdict {
  const lower = host.toLowerCase().replace(/^\[/, "").replace(/\]$/, "");

  if (BLOCKED_HOSTNAMES.has(lower)) return "blocked";

  // IPv4-mapped IPv6 (::ffff:127.0.0.1, ::ffff:7f00:1) folds to IPv4 rules.
  const mappedV4 = lower.includes(":") ? ipv4FromMappedIpv6(lower) : null;
  const canonicalV4 = mappedV4 ?? normalizeIpv4(lower);
  if (canonicalV4) {
    if (isLoopbackIpv4(canonicalV4)) return "loopback";
    return isBlockedIpv4(canonicalV4) ? "blocked" : "public";
  }

  if (lower.includes(":")) {
    if (lower === "::1") return "loopback";
    return isBlockedIpv6(lower) ? "blocked" : "public";
  }

  if (lower === "localhost") return "loopback";
  return "public";
}

/**
 * True when `address` (a resolved IP literal — v4 in any encoding / v6 / mapped)
 * is a public unicast address safe to connect to. Loopback is NOT public: this is
 * the strict allowlist used by the DNS-pinning outbound client in `ssrfAgent.ts`,
 * where even loopback must be opted into explicitly.
 */
export function isPublicUnicastAddress(address: string): boolean {
  return classifyHostLiteral(address) === "public";
}

class SsrfBlockedError extends Error {
  constructor(host: string) {
    super(`Outbound request to '${host}' is blocked (SSRF guard).`);
    this.name = "SsrfBlockedError";
  }
}

export { SsrfBlockedError };

/**
 * Throws {@link SsrfBlockedError} when `url` targets a disallowed host.
 * Allows http/https only. Loopback is permitted; private/link-local/metadata are
 * blocked unless `allowPrivateHosts` is set (the GCP metadata identity fetch).
 *
 * SOTA (2026): canonicalizes IPv4 alternative encodings (decimal, hex, octal,
 * short-form) AND IPv4-mapped IPv6 (`::ffff:127.0.0.1`) before range checks, so
 * `0x7f000001`, `2130706433`, and `::ffff:7f00:1` are all treated identically to
 * `127.0.0.1`. For DNS-rebinding protection on user-supplied URLs, fetch via the
 * DNS-pinning client in `ssrfAgent.ts` (or call
 * {@link assertOutboundFetchTargetResolved} and connect only to a checked IP).
 */
export function assertOutboundFetchTarget(url: string | URL, allowPrivateHosts = false): void {
  let parsed: URL;
  try {
    parsed = typeof url === "string" ? new URL(url) : url;
  } catch {
    throw new SsrfBlockedError(String(url));
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new SsrfBlockedError(parsed.protocol);
  }
  if (allowPrivateHosts) return;

  // Loopback is allowed (local dev/emulator); everything private/link-local is not.
  if (classifyHostLiteral(parsed.hostname) === "blocked") {
    throw new SsrfBlockedError(parsed.hostname.toLowerCase());
  }
}

/**
 * DNS-resolution-aware SSRF check for user-supplied URLs.
 *
 * Resolves the hostname to its IP addresses and checks each against the SSRF
 * block list. This closes the DNS-rebinding / TOCTOU window where a hostname
 * string check passes but the resolved IP is a private/metadata endpoint.
 *
 * **Note:** Full DNS pinning (forcing the request to connect to the resolved IP)
 * is provided by the outbound client in `ssrfAgent.ts`. This function is the
 * resolution + re-check gate; prefer the pinning client for user/config URLs.
 *
 * @returns The resolved IP addresses (for caller-side DNS pinning if desired).
 * @throws {SsrfBlockedError} if any resolved IP is private/link-local/metadata.
 */
export async function assertOutboundFetchTargetResolved(url: string | URL): Promise<string[]> {
  const parsed = typeof url === "string" ? new URL(url) : url;
  assertOutboundFetchTarget(parsed);

  const host = parsed.hostname.toLowerCase().replace(/^\[|\]$/g, "");

  // Skip DNS resolution for literal IPs (already checked above).
  if (normalizeIpv4(host) || host.includes(":")) return [host];
  if (host === "localhost") return ["127.0.0.1"];

  let addresses: { address: string }[];
  try {
    addresses = await lookup(host, { all: true });
  } catch {
    // DNS failure is not a security event — the fetch will fail on its own.
    return [];
  }

  for (const { address } of addresses) {
    if (classifyHostLiteral(address) === "blocked") {
      throw new SsrfBlockedError(`${host} -> ${address}`);
    }
  }

  return addresses.map((a) => a.address);
}
