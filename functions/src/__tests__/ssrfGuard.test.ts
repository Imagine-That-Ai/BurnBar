import { describe, expect, it } from "vitest";

import { assertOutboundFetchTarget, normalizeIpv4 } from "../ssrfGuard.js";

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
  it("blocks private and metadata hosts even when encoded as alternate IPv4 literals", () => {
    expect(() => assertOutboundFetchTarget("http://0x0a000001")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://0300.0250.0.1")).toThrow(/SSRF guard/);
    expect(() => assertOutboundFetchTarget("http://0251.0376.0251.0376")).toThrow(/SSRF guard/);
  });

  it("preserves the explicit local-development loopback exception", () => {
    expect(() => assertOutboundFetchTarget("http://127.1:8080")).not.toThrow();
    expect(() => assertOutboundFetchTarget("http://0x7f000001:8080")).not.toThrow();
  });
});
