import { describe, expect, it, vi, beforeEach } from "vitest";

const captureException = vi.fn();
const setSentryUser = vi.fn();

vi.mock("../../../packages/functions-shared/src/sentry.js", () => ({
  captureException,
  setSentryUser,
}));

/** Narrows a console log line to the fields the tests assert on, without a cast. */
function logEventFields(parsed: unknown): { event?: unknown; callable?: unknown } {
  if (typeof parsed !== "object" || parsed === null) return {};
  const fields: { event?: unknown; callable?: unknown } = {};
  if ("event" in parsed) fields.event = parsed.event;
  if ("callable" in parsed) fields.callable = parsed.callable;
  return fields;
}

describe("callable Sentry capture", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("withCallableLogging captures exceptions with callable context", async () => {
    const { withCallableLogging } = await import("../../../packages/functions-shared/src/logging.js");
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
    const { wrapRequestHandler } = await import("../../../packages/functions-shared/src/logging.js");
    const wrapped = wrapRequestHandler("stripeBurnBarProWebhook", async () => {
      throw new Error("webhook blew up");
    });
    const req = { headers: {}, header: () => undefined };
    const res = { status: vi.fn().mockReturnThis(), json: vi.fn(), send: vi.fn() };
    // Widen to the function seam (the healthManifest driveHandler pattern): the
    // fakes exercise only the header/status/json surface of the wrapped handler.
    const handler: unknown = wrapped;
    if (typeof handler !== "function") throw new Error("expected a callable handler");
    await expect(handler(req, res)).rejects.toThrow("webhook blew up");
    expect(captureException).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({
        callable: "stripeBurnBarProWebhook",
      }),
    );
  });

  it("wrapRequestHandler logs success when the handler returns", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const { wrapRequestHandler } = await import("../../../packages/functions-shared/src/logging.js");
    const wrapped = wrapRequestHandler("healthLive", async (_req, res) => {
      res.status(200).json({ status: "alive" });
    });
    const req = { headers: {}, header: () => undefined };
    const res = { status: vi.fn().mockReturnThis(), json: vi.fn(), send: vi.fn() };
    const handler: unknown = wrapped;
    if (typeof handler !== "function") throw new Error("expected a callable handler");
    await handler(req, res);
    const events = logSpy.mock.calls.map((call) => {
      const parsed: unknown = JSON.parse(String(call[0]));
      return logEventFields(parsed);
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
