import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  callable: vi.fn(),
  functions: vi.fn(),
  httpsCallable: vi.fn(),
}));

vi.mock("../lib/firebaseClient", () => ({
  functions: mocks.functions,
}));

vi.mock("firebase/functions", () => ({
  httpsCallable: mocks.httpsCallable,
}));

import { deleteDomainData, DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE } from "../lib/api";

/** Mirrors the FirebaseError surface the firebase/functions client throws. */
function callableError(code: string, message: string): Error & { code: string } {
  const err = new Error(message) as Error & { code: string };
  err.code = code;
  return err;
}

describe("deleteDomainData step-up gate surfacing", () => {
  beforeEach(() => {
    mocks.callable.mockReset();
    mocks.functions.mockReset();
    mocks.functions.mockReturnValue({ app: "test-functions" });
    mocks.httpsCallable.mockReset();
    mocks.httpsCallable.mockReturnValue(mocks.callable);
  });

  it("still sends the typed { domainId, confirm } payload on success", async () => {
    const res = {
      ok: true,
      domainId: "pensieve",
      deleted: { firestoreDocs: 2, storageObjects: 1 },
    };
    mocks.callable.mockResolvedValue({ data: res });

    await expect(deleteDomainData("pensieve")).resolves.toEqual(res);
    expect(mocks.httpsCallable).toHaveBeenCalledWith({ app: "test-functions" }, "deleteDomainData");
    expect(mocks.callable).toHaveBeenCalledWith({ domainId: "pensieve", confirm: true });
  });

  it("maps the trusted-device step-up rejection to the actionable console message", async () => {
    mocks.callable.mockRejectedValue(
      callableError(
        "functions/failed-precondition",
        "This high-risk action requires App Check, a fresh high-risk nonce, and a trusted-device action proof.",
      ),
    );

    await expect(deleteDomainData("pensieve")).rejects.toThrow(
      DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE,
    );
  });

  it("passes through non-step-up precondition failures verbatim (e.g. undeletable domains)", async () => {
    const original = callableError(
      "functions/failed-precondition",
      'The "audit_timeline" domain is not deletable here; use its revoke/erase action instead.',
    );
    mocks.callable.mockRejectedValue(original);

    await expect(deleteDomainData("audit_timeline")).rejects.toBe(original);
  });

  it("passes through unrelated errors verbatim", async () => {
    const original = callableError("functions/unauthenticated", "Sign in before deleting your data.");
    mocks.callable.mockRejectedValue(original);

    await expect(deleteDomainData("pensieve")).rejects.toBe(original);
  });
});
