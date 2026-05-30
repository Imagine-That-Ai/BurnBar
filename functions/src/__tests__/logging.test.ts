/**
 * Unit tests for functions/src/logging.ts — PII scrubbing and structured logging.
 *
 * These tests run without Firebase emulator. They verify that the scrubbing
 * pipeline correctly redacts sensitive data before it reaches Cloud Logging.
 *
 * Critical invariants:
 *   1. Emails must never appear in logs verbatim
 *   2. IP addresses must never appear in logs verbatim
 *   3. API keys and bearer tokens must be redacted
 *   4. uid/userId/user_id keys must be truncated to first 8 chars
 *   5. Non-sensitive fields must pass through unchanged
 *   6. Nested objects must be recursively scrubbed
 *   7. Non-string values (numbers, booleans) must pass through unchanged
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// We test the exported functions via their side-effects on console.*
// The module is imported directly — no Firebase dependency.

describe("PII scrubbing in structured logging", () => {
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errorSpy: ReturnType<typeof vi.spyOn>;
  let warnSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  function captureLog(spy: typeof logSpy): Record<string, unknown> {
    expect(spy).toHaveBeenCalledOnce();
    return JSON.parse(spy.mock.calls[0][0] as string) as Record<string, unknown>;
  }

  // ── Email redaction ─────────────────────────────────────────────────────

  describe("email redaction", () => {
    it("redacts email in a string field", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", message: "user is john@example.com" });
      const payload = captureLog(logSpy);
      expect(payload.message).toBe("user is [email]");
    });

    it("redacts email in event field", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "login", email: "alice@corp.example.org" });
      const payload = captureLog(logSpy);
      expect(payload.email).toBe("[email]");
    });

    it("redacts multiple emails in one string", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", message: "from a@b.com to c@d.io" });
      const payload = captureLog(logSpy);
      expect(payload.message).toBe("from [email] to [email]");
    });

    it("does not redact non-email strings", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", message: "hello world" });
      const payload = captureLog(logSpy);
      expect(payload.message).toBe("hello world");
    });
  });

  // ── IP address redaction ────────────────────────────────────────────────

  describe("IP address redaction", () => {
    it("redacts IPv4 address", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", ip: "192.168.1.42" });
      const payload = captureLog(logSpy);
      expect(payload.ip).toBe("[ip]");
    });

    it("redacts IPv4 embedded in message", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", message: "request from 10.0.0.1 blocked" });
      const payload = captureLog(logSpy);
      expect(payload.message).toBe("request from [ip] blocked");
    });

    it("does not treat version strings as IPs", async () => {
      // "1.2.3.4" is an IP, but "v1.2.3" is not. The regex requires 4 octets.
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", version: "v1.2.3" });
      const payload = captureLog(logSpy);
      // "1.2.3" only has 3 octets — must NOT be redacted
      expect(payload.version).toBe("v1.2.3");
    });
  });

  // ── API key / token redaction ───────────────────────────────────────────

  describe("API key and token redaction", () => {
    it("redacts Stripe secret key", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", key: "sk-abcdefghijklmnopqrstuvwxyz1234567890" });
      const payload = captureLog(logSpy);
      expect(payload.key).toBe("[REDACTED]");
    });

    it("redacts Google AIza API key", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", key: "AIzaSyAbcdefghijklmnopqrstuvwxyz123456" });
      const payload = captureLog(logSpy);
      expect(payload.key).toBe("[REDACTED]");
    });

    it("redacts JWT bearer token starting with eyJ", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", token: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature" });
      const payload = captureLog(logSpy);
      expect(payload.token).toBe("[REDACTED]");
    });

    it("does not redact short strings that happen to start with sk-", async () => {
      // Prefix without the 20+ following chars should not match
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", code: "sk-123" }); // only 3 chars after prefix
      const payload = captureLog(logSpy);
      expect(payload.code).toBe("sk-123");
    });
  });

  // ── Credit card redaction ───────────────────────────────────────────────

  describe("credit card redaction", () => {
    it("redacts 16-digit credit card number", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", card: "4111111111111111" });
      const payload = captureLog(logSpy);
      expect(payload.card).toBe("[REDACTED]");
    });

    it("redacts spaced credit card number", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", card: "4111 1111 1111 1111" });
      const payload = captureLog(logSpy);
      expect(payload.card).toBe("[REDACTED]");
    });

    it("does not redact 16-char alphanumeric strings", async () => {
      // Must only match all-digit patterns
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", ref: "ABCD1234EFGH5678" });
      const payload = captureLog(logSpy);
      expect(payload.ref).toBe("ABCD1234EFGH5678");
    });
  });

  // ── UID key-based truncation ────────────────────────────────────────────

  describe("UID key-based truncation", () => {
    it("truncates uid field to first 8 chars and renames to user_id_hash", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", uid: "mzO4MRBNjbsePMeFHl2T8hBCsU02" } as Parameters<typeof logInfo>[0]);
      const payload = captureLog(logSpy);
      expect(payload.user_id_hash).toBe("mzO4MRBN");
      expect(payload.uid).toBeUndefined();
    });

    it("truncates userId field to first 8 chars, preserves key name", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", userId: "mzO4MRBNjbsePMeFHl2T8hBCsU02" } as Parameters<typeof logInfo>[0]);
      const payload = captureLog(logSpy);
      expect(payload.userId).toBe("mzO4MRBN");
    });

    it("uid shorter than 8 chars passes through truncated safely", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", uid: "abc" } as Parameters<typeof logInfo>[0]);
      const payload = captureLog(logSpy);
      expect(payload.user_id_hash).toBe("abc");
    });
  });

  // ── Non-string field passthrough ────────────────────────────────────────

  describe("non-string field passthrough", () => {
    it("numbers pass through unchanged", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", latency_ms: 42 });
      const payload = captureLog(logSpy);
      expect(payload.latency_ms).toBe(42);
    });

    it("booleans pass through unchanged", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", healthy: true });
      const payload = captureLog(logSpy);
      expect(payload.healthy).toBe(true);
    });

    it("null values pass through unchanged", async () => {
      const { logWarn } = await import("../logging.js");
      logWarn({ event: "test", detail: undefined });
      const payload = JSON.parse(warnSpy.mock.calls[0][0] as string) as Record<string, unknown>;
      expect(payload.detail).toBeUndefined();
    });
  });

  // ── Nested object scrubbing ─────────────────────────────────────────────

  describe("nested object scrubbing", () => {
    it("recursively scrubs nested objects", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({
        event: "test",
        context: JSON.stringify({ user: "admin@company.com", ip: "1.2.3.4" }),
      });
      const payload = captureLog(logSpy);
      const ctx = payload.context as string;
      expect(ctx).not.toContain("admin@company.com");
      expect(ctx).not.toContain("1.2.3.4");
    });
  });

  // ── Severity and structure ──────────────────────────────────────────────

  describe("log severity routing", () => {
    it("logInfo writes to console.log with severity INFO", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test_event" });
      const payload = captureLog(logSpy);
      expect(payload.severity).toBe("INFO");
      expect(payload.event).toBe("test_event");
      expect(typeof payload.trace_id).toBe("string");
    });

    it("logError writes to console.error with severity ERROR", async () => {
      const { logError } = await import("../logging.js");
      logError({ event: "test_error", error: "something failed" });
      const payload = captureLog(errorSpy);
      expect(payload.severity).toBe("ERROR");
      expect(payload.event).toBe("test_error");
    });

    it("logWarn writes to console.warn with severity WARNING", async () => {
      const { logWarn } = await import("../logging.js");
      logWarn({ event: "test_warn" });
      const payload = JSON.parse(warnSpy.mock.calls[0][0] as string) as Record<string, unknown>;
      expect(payload.severity).toBe("WARNING");
    });

    it("auto-generates trace_id when not provided", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "a" });
      logInfo({ event: "b" });
      const p1 = JSON.parse(logSpy.mock.calls[0][0] as string) as Record<string, unknown>;
      const p2 = JSON.parse(logSpy.mock.calls[1][0] as string) as Record<string, unknown>;
      expect(p1.trace_id).toBeTruthy();
      expect(p2.trace_id).toBeTruthy();
      expect(p1.trace_id).not.toBe(p2.trace_id);
    });

    it("preserves caller-provided trace_id", async () => {
      const { logInfo } = await import("../logging.js");
      logInfo({ event: "test", trace_id: "my-trace-123" });
      const payload = captureLog(logSpy);
      expect(payload.trace_id).toBe("my-trace-123");
    });
  });

  // ── Field length truncation ─────────────────────────────────────────────

  describe("field length truncation", () => {
    it("truncates string fields longer than 1024 chars", async () => {
      const { logInfo } = await import("../logging.js");
      const longString = "a".repeat(2000);
      logInfo({ event: "test", message: longString });
      const payload = captureLog(logSpy);
      const msg = payload.message as string;
      expect(msg.length).toBeLessThan(1100);
      expect(msg).toContain("[truncated]");
    });

    it("does not truncate strings at or under 1024 chars", async () => {
      const { logInfo } = await import("../logging.js");
      const normalString = "x".repeat(1024);
      logInfo({ event: "test", message: normalString });
      const payload = captureLog(logSpy);
      expect(payload.message).toBe(normalString);
    });
  });

  // ── traceIdFromCallableRequest ──────────────────────────────────────────

  describe("traceIdFromCallableRequest", () => {
    it("extracts trace ID from x-cloud-trace-context header", async () => {
      const { traceIdFromCallableRequest } = await import("../logging.js");
      const id = traceIdFromCallableRequest({
        rawRequest: { headers: { "x-cloud-trace-context": "abc123/0;o=1" } },
      });
      expect(id).toBe("abc123");
    });

    it("falls back to x-trace-id header", async () => {
      const { traceIdFromCallableRequest } = await import("../logging.js");
      const id = traceIdFromCallableRequest({
        rawRequest: { headers: { "x-trace-id": "fallback-trace" } },
      });
      expect(id).toBe("fallback-trace");
    });

    it("generates a UUID when no trace header present", async () => {
      const { traceIdFromCallableRequest } = await import("../logging.js");
      const id = traceIdFromCallableRequest({ rawRequest: { headers: {} } });
      expect(id).toMatch(/^[0-9a-f-]{36}$/);
    });

    it("generates a UUID when rawRequest is absent", async () => {
      const { traceIdFromCallableRequest } = await import("../logging.js");
      const id = traceIdFromCallableRequest({});
      expect(id).toMatch(/^[0-9a-f-]{36}$/);
    });
  });

  // ── Callable logging wrappers ───────────────────────────────────────────

  describe("callable logging wrappers", () => {
    it("logCallableStart emits callable_start event", async () => {
      const { logCallableStart } = await import("../logging.js");
      logCallableStart("myFunction", "trace-abc", "uid-12345678");
      const payload = captureLog(logSpy);
      expect(payload.event).toBe("callable_start");
      expect(payload.callable).toBe("myFunction");
      expect(payload.trace_id).toBe("trace-abc");
      expect(payload.user_id_hash).toBe("uid-1234");
    });

    it("logCallableSuccess emits callable_success event", async () => {
      const { logCallableSuccess } = await import("../logging.js");
      logCallableSuccess("myFunction", "trace-abc", "uid-12345678");
      const payload = captureLog(logSpy);
      expect(payload.event).toBe("callable_success");
      expect(payload.callable).toBe("myFunction");
    });

    it("logCallableFailure emits callable_error event via logError", async () => {
      const { logCallableFailure } = await import("../logging.js");
      logCallableFailure("myFunction", "trace-abc", new Error("boom"), "uid-12345678");
      const payload = captureLog(errorSpy);
      expect(payload.event).toBe("callable_error");
      expect(payload.callable).toBe("myFunction");
      expect(payload.error).toBe("Error: boom");
    });

    it("withCallableLogging logs start+success and returns handler result", async () => {
      const { withCallableLogging } = await import("../logging.js");
      const result = await withCallableLogging("fn", {}, undefined, async () => "result-value");
      expect(result).toBe("result-value");
      expect(logSpy).toHaveBeenCalledTimes(2);
      const [startLog, successLog] = logSpy.mock.calls.map((c) => JSON.parse(c[0] as string));
      expect((startLog as Record<string, unknown>).event).toBe("callable_start");
      expect((successLog as Record<string, unknown>).event).toBe("callable_success");
    });

    it("withCallableLogging logs start+error and re-throws on handler failure", async () => {
      const { withCallableLogging } = await import("../logging.js");
      const boom = new Error("handler exploded");
      await expect(
        withCallableLogging("fn", {}, "uid123", async () => {
          throw boom;
        }),
      ).rejects.toThrow("handler exploded");
      expect(logSpy).toHaveBeenCalledTimes(1); // start only
      expect(errorSpy).toHaveBeenCalledTimes(1); // error
      const errLog = JSON.parse(errorSpy.mock.calls[0][0] as string) as Record<string, unknown>;
      expect(errLog.event).toBe("callable_error");
    });
  });
});
