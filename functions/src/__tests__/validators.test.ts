/**
 * Shared validator regression tests.
 *
 * Closes codex-gpt-5 FINDING-003 / OPUS-F-007: Stripe/billing redirect URLs must
 * reject non-HTTPS non-loopback hosts and parser-differential bypasses.
 */
import { describe, expect, it } from "vitest";

import { boundedHttpsURL } from "../callables/shared/validators.js";

describe("boundedHttpsURL", () => {
  it("accepts plain HTTPS URLs", () => {
    expect(boundedHttpsURL("https://burnbar.ai/success", "successUrl")).toBe(
      "https://burnbar.ai/success",
    );
  });

  it("accepts exact loopback localhost over http", () => {
    expect(boundedHttpsURL("http://localhost:3000/callback", "returnUrl")).toBe(
      "http://localhost:3000/callback",
    );
  });

  it("accepts 127.0.0.1 loopback over http", () => {
    expect(boundedHttpsURL("http://127.0.0.1:3000/callback", "returnUrl")).toBe(
      "http://127.0.0.1:3000/callback",
    );
  });

  it("accepts ::1 loopback over http", () => {
    expect(boundedHttpsURL("http://[::1]:3000/callback", "returnUrl")).toBe(
      "http://[::1]:3000/callback",
    );
  });

  it("rejects localhost-substring attacker domains", () => {
    expect(() => boundedHttpsURL("http://localhost.attacker.example", "successUrl")).toThrow(
      /must be HTTPS/,
    );
    expect(() => boundedHttpsURL("http://dev.localhost:3000/callback", "successUrl")).toThrow(
      /must be HTTPS/,
    );
    expect(() => boundedHttpsURL("http://malocalhost.com", "cancelUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("http://evil-localhost.example", "returnUrl")).toThrow(
      /must be HTTPS/,
    );
  });

  it("rejects non-loopback http URLs", () => {
    expect(() => boundedHttpsURL("http://burnbar.ai/callback", "successUrl")).toThrow(
      /must be HTTPS/,
    );
  });

  it("rejects non-HTTP schemes", () => {
    expect(() => boundedHttpsURL("javascript:alert(1)", "successUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("file:///etc/passwd", "cancelUrl")).toThrow(/must be HTTPS/);
  });

  it("rejects protocol-relative URLs", () => {
    expect(() => boundedHttpsURL("//attacker.example", "successUrl")).toThrow(/must be a valid URL/);
  });

  it("rejects userinfo tricks", () => {
    expect(() => boundedHttpsURL("https://burnbar.ai@attacker.example", "successUrl")).toThrow(
      /must not include credentials/,
    );
  });

  it("rejects IPv4 loopback obfuscation", () => {
    expect(() => boundedHttpsURL("http://127.1", "successUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("http://2130706433", "successUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("http://017700000001", "successUrl")).toThrow(/must be HTTPS/);
  });

  describe("with allowedHosts", () => {
    it("allows an allowlisted HTTPS origin", () => {
      expect(boundedHttpsURL("https://burnbar.ai/success", "successUrl", ["burnbar.ai"])).toBe(
        "https://burnbar.ai/success",
      );
    });

    it("rejects a non-allowlisted HTTPS origin", () => {
      expect(() => boundedHttpsURL("https://attacker.example", "successUrl", ["burnbar.ai"])).toThrow(
        /not an allowed redirect destination/,
      );
    });

    it("allows loopback even when an allowlist is configured", () => {
      expect(boundedHttpsURL("http://localhost:3000/callback", "returnUrl", ["burnbar.ai"])).toBe(
        "http://localhost:3000/callback",
      );
      expect(boundedHttpsURL("http://127.0.0.1:3000/callback", "returnUrl", ["burnbar.ai"])).toBe(
        "http://127.0.0.1:3000/callback",
      );
      expect(boundedHttpsURL("http://[::1]:3000/callback", "returnUrl", ["burnbar.ai"])).toBe(
        "http://[::1]:3000/callback",
      );
    });

    it("matches host with explicit port when configured", () => {
      expect(
        boundedHttpsURL("https://burnbar.ai:8080/callback", "returnUrl", ["burnbar.ai:8080"]),
      ).toBe("https://burnbar.ai:8080/callback");
    });

    it("rejects host with non-allowlisted explicit port", () => {
      expect(() =>
        boundedHttpsURL("https://burnbar.ai:8080/callback", "returnUrl", ["burnbar.ai"]),
      ).toThrow(/not an allowed redirect destination/);
    });

    it("rejects localhost-substring domains even on allowlisted HTTPS scheme", () => {
      expect(() =>
        boundedHttpsURL("https://localhost.attacker.example", "successUrl", ["burnbar.ai"]),
      ).toThrow(/not an allowed redirect destination/);
    });
  });
});
