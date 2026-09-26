/**
 * Unit tests for IPv6 scrubbing in functions/src/logging.ts.
 *
 * The structured-log scrubber redacts IPv6 literals (full, compressed,
 * loopback, and IPv4-mapped forms) to "[ip]", matching the long-standing IPv4
 * behavior. Negative controls prove clock times, version strings, Rust paths,
 * and long hex correlation IDs are left intact.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

describe("IPv6 address redaction", () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function capturePayload(): Record<string, unknown> {
    const parsed: unknown = JSON.parse(String(logSpy.mock.calls.at(-1)?.[0]));
    if (!isRecord(parsed)) throw new Error("Expected structured console payload");
    return parsed;
  }

  it.each([
    ["full form", "2001:0db8:85a3:0000:0000:8a2e:0370:7334"],
    ["compressed form", "2001:db8:85a3::8a2e:370:7334"],
    ["short compressed form", "2001:db8::1"],
    ["loopback", "::1"],
    ["link-local prefix", "fe80::"],
    ["IPv4-mapped", "::ffff:192.0.2.1"],
    ["uppercase hex", "2001:DB8::1"],
  ])("redacts a bare %s address", async (_label, address) => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", ip: address });
    expect(capturePayload().ip).toBe("[ip]");
  });

  it("redacts IPv6 embedded in a message and beside IPv4", async () => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", message: "from 2001:db8::1 then 10.0.0.5" });
    expect(capturePayload().message).toBe("from [ip] then [ip]");
  });

  it("redacts a bracketed IPv6 socket address, keeping the port visible", async () => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", peer: "[2001:db8::1]:8080" });
    expect(capturePayload().peer).toBe("[[ip]]:8080");
  });

  it("redacts IPv6 at the end of a sentence without eating the period", async () => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", message: "ping ::1." });
    expect(capturePayload().message).toBe("ping [ip].");
  });

  it("redacts a zoned address while leaving the zone id", async () => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", peer: "fe80::1%eth0" });
    expect(capturePayload().peer).toBe("[ip]%eth0");
  });

  it.each([
    ["clock time", "at 12:34:56 today"],
    ["version string", "v1.2.3"],
    ["Rust path", "use std::io here"],
    ["turbofish", "collect::<Vec> done"],
    ["double-colon word", "key::value pair"],
    ["git SHA", "0123456789abcdef0123456789abcdef01234567"],
    ["trace id", "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"],
  ])("does not redact %s", async (_label, value) => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", note: value });
    expect(capturePayload().note).toBe(value);
  });

  it("redacts MAC addresses (device-identifying, same treatment as IPs)", async () => {
    const { logInfo } = await import("../../../packages/functions-shared/src/logging.js");
    logInfo({ event: "test", note: "MAC 00:1B:44:11:3A:B7 seen" });
    expect(capturePayload().note).toBe("MAC [ip] seen");
  });
});
