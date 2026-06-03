import { describe, expect, it } from "vitest";

import { passkeySetupErrorMessage } from "../components/account/PasskeyEnrollment";

describe("passkeySetupErrorMessage", () => {
  it("normalizes duplicate passkey errors", () => {
    expect(passkeySetupErrorMessage(new Error("InvalidStateError"))).toBe(
      "A passkey is already registered for this account on this authenticator.",
    );
  });

  it("normalizes cancelled WebAuthn prompts", () => {
    expect(passkeySetupErrorMessage(new Error("NotAllowedError"))).toBe(
      "Passkey setup was cancelled.",
    );
  });

  it("normalizes Safari document focus failures", () => {
    expect(passkeySetupErrorMessage(new Error("The document is not focused."))).toBe(
      "Safari needs the page focused before passkey setup. Click the page once, then create the passkey again.",
    );
  });
});
