import { describe, expect, it } from "vitest";

import { assertOutboundFetchTarget, isPublicUnicastAddress, normalizeIpv4 } from "../ssrfGuard.js";

describe("normalizeIpv4", () => {
  it("normalizes decimal, hex, octal, and short-form IPv4 literals", () => {
    expect(normalizeIpv4("2130706433")).toBe("127.0.0.1");
    expect(normalizeIpv4("0x7f000001")).toBe("127.0.0.1");
    expect(normalizeIpv4("017700000001")).toBe("127.0.0.1");
    expect(normalizeIpv4("0177.0.0.1")).toBe("127.0.0.1");
    expect(normalizeIpv4("127.1")).toBe("127.0.0.1");
    expect(normalizeIpv4("127.0.1")).toBe("127.0.0.1");
    expect(normalizeIpv4("10.1")).toBe("10.0.0.1");
    expect(normalizeIpv4("192.168.1")).toBe("192.168.0.1");
  });

  it("rejects invalid IPv4 literals", () => {
    expect(normalizeIpv4("256.0.0.1")).toBeNull();
    expect(normalizeIpv4("1.16777216")).toBeNull();
    expect(normalizeIpv4("1.2.65536")).toBeNull();
    expect(normalizeIpv4("1.2.3.256")).toBeNull();
    expect(normalizeIpv4("example.com")).toBeNull();
  });
});

describe("assertOutboundFetchTarget", () => {
  it("blocks the cloud metadata service in every spelling", () => {
    // dotted-decimal, decimal, hex, and the metadata hostnames.
    expect(() => assertOutboundFetchTarget("http://169.254.169.254/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://2852039166/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://0xa9fea9fe/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://metadata.google.internal/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://metadata/")).toThrow(/SSRF guard/);
  });

  it("blocks loopback encoded as alternate IPv4 literals", () => {
    expect(() => assertOutboundFetchTarget("http://0x7f000001")).not.toThrow(); // 127.x is the dev exception
    // ...but every other private/link-local alt-encoding is blocked:
    expect(() => assertOutboundFetchTarget("http://0x0a000001")).toThrow(/SSRF guard/); // 10.0.0.1
    expect(() => assertOutboundFetchTarget("http://0300.0250.0.1")).toThrow(/SSRF guard/); // 192.168.0.1
    expect(() => assertOutboundFetchTarget("http://0251.0376.0251.0376")).toThrow(/SSRF guard/);
  });

  it("blocks IPv4-mapped IPv6 forms of loopback and private ranges", () => {
    expect(() => assertOutboundFetchTarget("http://[::ffff:169.254.169.254]/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://[::ffff:10.0.0.1]/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://[::ffff:192.168.0.1]/")).toThrow(/SSRF guard/);
    // hextet form of 169.254.169.254 -> ::ffff:a9fe:a9fe
    expect(() => assertOutboundFetchTarget("http://[::ffff:a9fe:a9fe]/")).toThrow(/SSRF guard/);
  });

  it("blocks RFC1918, CGNAT, link-local, ULA, multicast, and reserved ranges", () => {
    expect(() => assertOutboundFetchTarget("http://10.1.2.3/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://172.16.0.1/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://172.31.255.255/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://192.168.5.5/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://100.64.0.1/")).toThrow(/SSRF guard/); // CGNAT
    expect(() => assertOutboundFetchTarget("http://0.0.0.0/")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://224.0.0.1/")).toThrow(/SSRF guard/); // multicast
    expect(() => assertOutboundFetchTarget("http://240.0.0.1/")).toThrow(/SSRF guard/); // reserved
    expect(() => assertOutboundFetchTarget("http://[fc00::1]/")).toThrow(/SSRF guard/); // ULA
    expect(() => assertOutboundFetchTarget("http://[fe80::1]/")).toThrow(/SSRF guard/); // link-local
    expect(() => assertOutboundFetchTarget("http://[febf::1]/")).toThrow(/SSRF guard/); // fe80::/10 upper
    expect(() => assertOutboundFetchTarget("http://[ff02::1]/")).toThrow(/SSRF guard/); // multicast
    expect(() => assertOutboundFetchTarget("http://[::]/")).toThrow(/SSRF guard/); // unspecified
  });

  it("rejects non-http(s) protocols", () => {
    expect(() => assertOutboundFetchTarget("file:///etc/passwd")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("gopher://evil/")).toThrow(/SSRF guard/);
  });

  it("lets a normal public host through the string gate", () => {
    expect(() => assertOutboundFetchTarget("https://api.openai.com/v1/models")).not.toThrow();
    expect(() => assertOutboundFetchTarget("https://example.com/")).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://8.8.8.8/")).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://1.1.1.1/")).not.toThrow();
  });

  it("preserves the explicit local-development loopback exception", () => {
    expect(() => assertOutboundFetchTarget("http://127.1:8080")).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://0x7f000001:8080")).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://localhost:8080")).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://[::1]:8080")).not.toThrow();
  });

  it("preserves the sanctioned metadata fetch via allowPrivateHosts", () => {
    expect(() => assertOutboundFetchTarget("http://metadata.google.internal/computeMetadata/v1/", true)).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://169.254.169.254/", true)).not.toThrow();
  });
});

describe("isPublicUnicastAddress (DNS-pin allowlist)", () => {
  it("accepts public unicast IPs", () => {
    expect(isPublicUnicastAddress("8.8.8.8")).toBe(true);
    expect(isPublicUnicastAddress("1.1.1.1")).toBe(true);
    expect(isPublicUnicastAddress("2606:4700:4700::1111")).toBe(true);
  });

  it("rejects loopback, private, link-local, and metadata addresses", () => {
    // Loopback is NOT public — even the dev-exception loopback is rejected here.
    expect(isPublicUnicastAddress("127.0.0.1")).toBe(false);
    expect(isPublicUnicastAddress("::1")).toBe(false);
    expect(isPublicUnicastAddress("10.0.0.1")).toBe(false);
    expect(isPublicUnicastAddress("169.254.169.254")).toBe(false);
    expect(isPublicUnicastAddress("::ffff:169.254.169.254")).toBe(false);
    expect(isPublicUnicastAddress("fc00::1")).toBe(false);
    expect(isPublicUnicastAddress("fe80::1")).toBe(false);
  });
});
