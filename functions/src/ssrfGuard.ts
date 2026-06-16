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
 * SOTA hardening (2026): normalizes IPv4 alternative encodings (decimal, hex,
 * octal, short-form) to dotted-decimal before range checks, so a host like
 * `0x7f000001` or `2130706433` is treated identically to `127.0.0.1`. Per
 * OWASP SSRF Prevention guidance warns that hostname checks alone cannot stop
 * DNS rebinding / TOCTOU attacks; user-supplied URL fetches must also call
 * `assertOutboundFetchTargetResolved` and either pin the resolved address or
 * disable redirects before the request is sent.
 */

import { lookup } from "node:dns/promises";

const BLOCKED_HOSTNAMES = new Set(["metadata.google.internal", "metadata", "metadata.goog"]);

const BLOCKED_IPV4_PREFIXES = [
  "169.254.", // link-local incl. 169.254.169.254 cloud metadata
  "10.", // RFC1918
  "192.168.", // RFC1918
  "0.", // "this network"
];

function isBlockedIpv4(host: string): boolean {
  // 172.16.0.0/12 is 172.16.x.x .. 172.31.x.x
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(host)) return true;
  return BLOCKED_IPV4_PREFIXES.some((prefix) => host.startsWith(prefix));
}

function isBlockedIpv6(host: string): boolean {
  const h = host.replace(/^\[/, "").replace(/\]$/, "").toLowerCase();
  if (h === "::") return true;
  if (h.startsWith("fe80:")) return true; // link-local
  if (h.startsWith("fc") || h.startsWith("fd")) return true; // unique local fc00::/7
  if (h.includes("169.254.")) return true; // IPv4-mapped link-local/metadata
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

function dottedIpv4FromInteger(value: number): string {
  const a = Math.floor(value / 2 ** 24) % 256;
  const b = Math.floor(value / 2 ** 16) % 256;
  const c = Math.floor(value / 2 ** 8) % 256;
  const d = value % 256;
  return `${a}.${b}.${c}.${d}`;
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

  const nums: number[] = [];
  for (const part of parts) {
    const numericPart = parseIpv4NumericPart(part);
    if (numericPart === null) return null;
    nums.push(numericPart);
  }

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

class SsrfBlockedError extends Error {
  constructor(host: string) {
    super(`Outbound request to '${host}' is blocked (SSRF guard).`);
    this.name = "SsrfBlockedError";
  }
}

/**
 * Throws {@link SsrfBlockedError} when `url` targets a disallowed host.
 * Allows http/https only. Loopback is permitted; private/link-local/metadata are
 * blocked unless `allowPrivateHosts` is set (the GCP metadata identity fetch).
 *
 * SOTA (2026): normalizes IPv4 alternative encodings (decimal, hex, octal,
 * short-form) before range checks so `0x7f000001` and `2130706433` are treated
 * identically to `127.0.0.1`. For DNS-rebinding protection on user-supplied
 * URLs, call {@link assertOutboundFetchTargetResolved} and connect only to a
 * checked resolved address, or disable redirects and re-check every redirect.
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

  const host = parsed.hostname.toLowerCase();
  if (BLOCKED_HOSTNAMES.has(host)) {
    throw new SsrfBlockedError(host);
  }
  // Loopback is allowed (local dev/emulator); everything private/link-local is not.
  if (host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]") {
    return;
  }

  // IPv6 check (unchanged).
  if (host.includes(":") && isBlockedIpv6(host)) {
    throw new SsrfBlockedError(host);
  }

  // IPv4 check with normalization: catches decimal/hex/octal/short-form
  // encodings that bypass the old dotted-decimal-only regex. Closes
  // OPUS-F-007 / GLM FINDING-009 / Kimi (SSRF guard gaps).
  const normalized = normalizeIpv4(host);
  if (normalized && isBlockedIpv4(normalized)) {
    throw new SsrfBlockedError(host);
  }

  // Also check if loopback was expressed in alternative encoding.
  if (normalized && (normalized === "127.0.0.1" || normalized.startsWith("127."))) {
    return;
  }
}

/**
 * DNS-resolution-aware SSRF check for user-supplied URLs.
 *
 * Resolves the hostname to its IP addresses and checks each against the SSRF
 * block list. This closes the DNS-rebinding / TOCTOU window where a hostname
 * string check passes but the resolved IP is a private/metadata endpoint.
 *
 * **Note:** Full DNS pinning (forcing `fetch` to connect to the resolved IP)
 * requires a custom HTTP agent and is left to the caller. This function provides
 * the resolution + re-check gate that callers must use before any fetch of a
 * user/config-supplied URL.
 *
 * @returns The resolved IP addresses (for caller-side DNS pinning if desired).
 * @throws {SsrfBlockedError} if any resolved IP is private/link-local/metadata.
 */
export async function assertOutboundFetchTargetResolved(url: string | URL, allowPrivateHosts = false): Promise<string[]> {
  const parsed = typeof url === "string" ? new URL(url) : url;
  assertOutboundFetchTarget(parsed, allowPrivateHosts);
  if (allowPrivateHosts) return [];

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
    const lowerAddr = address.toLowerCase();
    if (BLOCKED_HOSTNAMES.has(lowerAddr)) {
      throw new SsrfBlockedError(`${host} -> ${address}`);
    }
    const normV4 = normalizeIpv4(lowerAddr);
    if (normV4 && isBlockedIpv4(normV4)) {
      throw new SsrfBlockedError(`${host} -> ${address}`);
    }
    if (lowerAddr.includes(":") && isBlockedIpv6(lowerAddr)) {
      throw new SsrfBlockedError(`${host} -> ${address}`);
    }
  }

  return addresses.map((a) => a.address);
}
