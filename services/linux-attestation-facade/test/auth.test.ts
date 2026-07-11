import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { GoogleOidcAuthenticator, type IdTokenVerifier } from "../src/googleAdapters.js";
import { PublicError } from "../src/errors.js";

function verifier(payload: { aud?: string; email?: string; email_verified?: boolean }): IdTokenVerifier {
  return { async verifyIdToken() { return { getPayload: () => payload }; } };
}

describe("GoogleOidcAuthenticator", () => {
  it("accepts only the exact audience and verified service account", async () => {
    const auth = new GoogleOidcAuthenticator("https://verifier.example", "caller@example.iam.gserviceaccount.com", verifier({
      aud: "https://verifier.example", email: "caller@example.iam.gserviceaccount.com", email_verified: true,
    }));
    await auth.authenticate("token");
  });

  for (const [name, payload] of [
    ["wrong audience", { aud: "https://other.example", email: "caller@example.iam.gserviceaccount.com", email_verified: true }],
    ["wrong caller", { aud: "https://verifier.example", email: "other@example.iam.gserviceaccount.com", email_verified: true }],
    ["unverified email", { aud: "https://verifier.example", email: "caller@example.iam.gserviceaccount.com", email_verified: false }],
  ] as const) {
    it(`rejects ${name}`, async () => {
      const auth = new GoogleOidcAuthenticator("https://verifier.example", "caller@example.iam.gserviceaccount.com", verifier(payload));
      await assert.rejects(auth.authenticate("token"), (error: unknown) => error instanceof PublicError && error.code === "unauthorized");
    });
  }
});
