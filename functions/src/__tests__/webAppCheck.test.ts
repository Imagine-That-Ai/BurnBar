import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/webAppCheck.js";

const { parsePublicKeyJwk, ESCROW_WEB_PLATFORM } = __testing__;

const EC_PUBLIC_JWK = {
  kty: "EC",
  crv: "P-256",
  x: "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
  y: "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0",
  use: "enc",
};

describe("parsePublicKeyJwk", () => {
  it("accepts a valid EC public JWK and derives a stable fingerprint", () => {
    const a = parsePublicKeyJwk({ ...EC_PUBLIC_JWK });
    // Key order in the input must not change the fingerprint (canonicalized).
    const b = parsePublicKeyJwk({ use: "enc", y: EC_PUBLIC_JWK.y, x: EC_PUBLIC_JWK.x, crv: "P-256", kty: "EC" });
    expect(a.fingerprint).toMatch(/^[0-9a-f]{64}$/);
    expect(a.fingerprint).toBe(b.fingerprint);
  });

  it("rejects JWKs that carry private key material", () => {
    expect(() => parsePublicKeyJwk({ ...EC_PUBLIC_JWK, d: "PRIVATE" })).toThrow(/private key material/);
    expect(() => parsePublicKeyJwk({ kty: "RSA", n: "x", e: "AQAB", p: "secret" })).toThrow(/private/);
    expect(() => parsePublicKeyJwk({ kty: "oct", k: "symmetric-secret" })).toThrow();
  });

  it("rejects unsupported key types", () => {
    expect(() => parsePublicKeyJwk({ kty: "oct" })).toThrow(/EC, RSA, or OKP/);
    expect(() => parsePublicKeyJwk({})).toThrow();
  });

  it("rejects non-object inputs", () => {
    expect(() => parsePublicKeyJwk(null)).toThrow();
    expect(() => parsePublicKeyJwk("jwk")).toThrow();
    expect(() => parsePublicKeyJwk([EC_PUBLIC_JWK])).toThrow();
  });

  it("rejects oversized JWK string fields", () => {
    expect(() => parsePublicKeyJwk({ ...EC_PUBLIC_JWK, x: "A".repeat(5000) })).toThrow(/too large/);
  });

  it("strips unknown non-scalar fields from the sanitized JWK", () => {
    const { jwk } = parsePublicKeyJwk({ ...EC_PUBLIC_JWK, junk: { nested: true } });
    expect("junk" in jwk).toBe(false);
    expect(jwk.kty).toBe("EC");
  });

  it("exposes the Web platform constant", () => {
    expect(ESCROW_WEB_PLATFORM).toBe("Web");
  });
});
