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

  it("wrapRequestHandler captures exceptions with request context", async () => {
    const { wrapRequestHandler } = await import("../logging.js");
    const wrapped = wrapRequestHandler("stripeBurnBarProWebhook", async () => {
      throw new Error("webhook blew up");
    });
    const req = { headers: {}, header: () => undefined };
    const res = { status: vi.fn().mockReturnThis(), json: vi.fn(), send: vi.fn() };
    await expect(wrapped(req as never, res as never)).rejects.toThrow("webhook blew up");
    expect(captureException).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({
        callable: "stripeBurnBarProWebhook",
      }),
    );
  });

  it("wrapRequestHandler logs success when the handler returns", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const { wrapRequestHandler } = await import("../logging.js");
    const wrapped = wrapRequestHandler("healthLive", async (_req, res) => {
      res.status(200).json({ status: "alive" });
    });
    const req = { headers: {}, header: () => undefined };
    const res = { status: vi.fn().mockReturnThis(), json: vi.fn(), send: vi.fn() };
    await wrapped(req as never, res as never);
    const events = logSpy.mock.calls.map((call) => {
      const parsed: unknown = JSON.parse(String(call[0]));
      return parsed as { event?: string; callable?: string };
    });
    expect(events.some((payload) => payload.event === "callable_start" && payload.callable === "healthLive")).toBe(
      true,
    );
    expect(events.some((payload) => payload.event === "callable_success" && payload.callable === "healthLive")).toBe(
      true,
    );
    logSpy.mockRestore();
  });
});
