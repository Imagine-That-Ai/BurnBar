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
 */

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
  if (host.includes(":") && isBlockedIpv6(host)) {
    throw new SsrfBlockedError(host);
  }
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) && isBlockedIpv4(host)) {
    throw new SsrfBlockedError(host);
  }
}
