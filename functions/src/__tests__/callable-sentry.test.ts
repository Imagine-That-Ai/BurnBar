import { describe, expect, it, vi, beforeEach } from "vitest";

const captureException = vi.fn();
const setSentryUser = vi.fn();

vi.mock("../sentry.js", () => ({
  captureException,
  setSentryUser,
}));

describe("callable Sentry capture", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("withCallableLogging captures exceptions with callable context", async () => {
    const { withCallableLogging } = await import("../logging.js");
    await expect(
      withCallableLogging("testCallable", { rawRequest: { headers: {} } }, "uid123456789012345678901234", async () => {
        throw new Error("callable blew up");
      }),
    ).rejects.toThrow("callable blew up");

    expect(setSentryUser).toHaveBeenCalledWith("uid123456789012345678901234");
    expect(captureException).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({
        callable: "testCallable",
        user_id_hash: "uid12345",
      }),
    );
  });
});
