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

import { confirmRecovery } from "../lib/api";

describe("recovery callable payloads", () => {
  beforeEach(() => {
    mocks.callable.mockReset();
    mocks.callable.mockResolvedValue({ data: { ok: true } });
    mocks.functions.mockReset();
    mocks.functions.mockReturnValue({ app: "test-functions" });
    mocks.httpsCallable.mockReset();
    mocks.httpsCallable.mockReturnValue(mocks.callable);
  });

  it("omits verificationHash for contact recovery confirmation", async () => {
    await expect(confirmRecovery("rec_contact")).resolves.toEqual({ ok: true });

    expect(mocks.httpsCallable).toHaveBeenCalledWith({ app: "test-functions" }, "confirmRecovery");
    expect(mocks.callable).toHaveBeenCalledWith({ recoveryId: "rec_contact" });
    expect(Object.hasOwn(mocks.callable.mock.calls[0][0], "verificationHash")).toBe(false);
  });

  it("omits nullish runtime values instead of sending verificationHash as null", async () => {
    await expect(confirmRecovery("rec_contact", null as unknown as string)).resolves.toEqual({
      ok: true,
    });

    expect(mocks.callable).toHaveBeenCalledWith({ recoveryId: "rec_contact" });
    expect(Object.hasOwn(mocks.callable.mock.calls[0][0], "verificationHash")).toBe(false);
  });

  it("sends verificationHash when re-confirming a recovery key", async () => {
    const verificationHash = "a".repeat(64);

    await expect(confirmRecovery("rec_key", verificationHash)).resolves.toEqual({ ok: true });

    expect(mocks.callable).toHaveBeenCalledWith({ recoveryId: "rec_key", verificationHash });
  });
});
