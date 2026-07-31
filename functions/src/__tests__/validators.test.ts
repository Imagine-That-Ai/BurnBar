/**
 * Shared validator regression tests.
 *
 * Closes codex-gpt-5 FINDING-003 / OPUS-F-007: Stripe/billing redirect URLs must
 * reject non-HTTPS non-loopback hosts and parser-differential bypasses.
 */
import { describe, expect, it } from "vitest";

import {
  boundedHttpsURL,
  requireRoamingProfileEnvelope,
  roamingProfileAADContext,
} from "../callables/shared/validators.js";

describe("boundedHttpsURL", () => {
  it("accepts plain HTTPS URLs", () => {
    expect(boundedHttpsURL("https://burnbar.ai/success", "successUrl")).toBe("https://burnbar.ai/success");
  });

  it("accepts exact loopback localhost over http", () => {
    expect(boundedHttpsURL("http://localhost:3000/callback", "returnUrl")).toBe("http://localhost:3000/callback");
  });

  it("accepts 127.0.0.1 loopback over http", () => {
    expect(boundedHttpsURL("http://127.0.0.1:3000/callback", "returnUrl")).toBe("http://127.0.0.1:3000/callback");
  });

  it("accepts ::1 loopback over http", () => {
    expect(boundedHttpsURL("http://[::1]:3000/callback", "returnUrl")).toBe("http://[::1]:3000/callback");
  });

  it("rejects localhost-substring attacker domains", () => {
    expect(() => boundedHttpsURL("http://localhost.attacker.example", "successUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("http://dev.localhost:3000/callback", "successUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("http://malocalhost.com", "cancelUrl")).toThrow(/must be HTTPS/);
    expect(() => boundedHttpsURL("http://evil-localhost.example", "returnUrl")).toThrow(/must be HTTPS/);
  });

  it("rejects non-loopback http URLs", () => {
    expect(() => boundedHttpsURL("http://burnbar.ai/callback", "successUrl")).toThrow(/must be HTTPS/);
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

  it("enforces exact non-loopback hosts when an allowlist is configured", () => {
    const allowlist = ["burnbar.ai", "www.burnbar.ai", "preview.burnbar.ai:8443"];

    expect(boundedHttpsURL("https://burnbar.ai/subscribe?status=success", "successUrl", allowlist)).toBe(
      "https://burnbar.ai/subscribe?status=success",
    );
    expect(boundedHttpsURL("https://WWW.BURNBAR.AI/subscribe", "returnUrl", allowlist)).toBe(
      "https://www.burnbar.ai/subscribe",
    );
    expect(boundedHttpsURL("https://preview.burnbar.ai:8443/subscribe", "returnUrl", allowlist)).toBe(
      "https://preview.burnbar.ai:8443/subscribe",
    );

    expect(() => boundedHttpsURL("https://attacker.example/subscribe", "successUrl", allowlist)).toThrow(
      /approved redirect host/,
    );
    expect(() => boundedHttpsURL("https://burnbar.ai.attacker.example/subscribe", "successUrl", allowlist)).toThrow(
      /approved redirect host/,
    );
    expect(() => boundedHttpsURL("https://preview.burnbar.ai/subscribe", "returnUrl", allowlist)).toThrow(
      /approved redirect host/,
    );
  });

  it("keeps exact loopback development URLs available with a production allowlist", () => {
    expect(boundedHttpsURL("http://localhost:4321/subscribe", "returnUrl", ["burnbar.ai"])).toBe(
      "http://localhost:4321/subscribe",
    );
    expect(boundedHttpsURL("http://127.0.0.1:4321/subscribe", "returnUrl", ["burnbar.ai"])).toBe(
      "http://127.0.0.1:4321/subscribe",
    );
  });
});

describe("roaming profile CloudVault validators", () => {
  const uid = "alice-roaming-uid";

  function sealedPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      schemaVersion: 2,
      algorithm: "AES-256-GCM",
      keyVersion: 1,
      vaultKeyID: `v1_${"a".repeat(32)}`,
      sealedBoxBase64: "Q2lwaGVydGV4dA==",
      aad: roamingProfileAADContext(uid),
      ...overrides,
    };
  }

  it("builds the stable roaming profile aad context", () => {
    expect(roamingProfileAADContext(uid)).toBe(
      "OpenBurnBar-CloudVault-aad-v2|alice-roaming-uid|roaming_profile|current|sealedPayload|2|OpenBurnBar-RoamingProfile-v1",
    );
  });

  it("accepts a strict sealed payload envelope for the current user", () => {
    expect(requireRoamingProfileEnvelope(sealedPayload(), uid)).toEqual(sealedPayload());
  });

  it("rejects wrong users or generic sealed-payload aad", () => {
    expect(() => requireRoamingProfileEnvelope(sealedPayload(), "bob-roaming-uid")).toThrow(
      /CloudVault document context/,
    );
    expect(() =>
      requireRoamingProfileEnvelope(sealedPayload({ aad: "OpenBurnBar-CloudVaultSealedPayload-v2" }), uid),
    ).toThrow(/CloudVault document context/);
  });

  it("rejects non-envelope or malformed envelope fields", () => {
    expect(() => requireRoamingProfileEnvelope({ routerMode: "same_model_failover" }, uid)).toThrow(/algorithm/);
    expect(() => requireRoamingProfileEnvelope(sealedPayload({ vaultKeyID: "v1_nothex" }), uid)).toThrow(
      /vault key id/,
    );
    expect(() => requireRoamingProfileEnvelope(sealedPayload({ sealedBoxBase64: "not base64!" }), uid)).toThrow(
      /base64/,
    );
  });
});
