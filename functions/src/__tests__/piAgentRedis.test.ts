import { describe, expect, it } from "vitest";
import {
  redactPiAgentConnectionDoc,
  redactPiAgentRedisURL,
  validatePiAgentRedisURLForStorage,
} from "../piAgent.js";
import type { PiAgentConnectionDoc } from "../types.js";

describe("Pi Agent Redis URL secret handling", () => {
  it("stores only credential-free Redis URLs", () => {
    expect(validatePiAgentRedisURLForStorage("redis://127.0.0.1:6379/0")).toBe("redis://127.0.0.1:6379/0");
    expect(() => validatePiAgentRedisURLForStorage("redis://:password@redis.internal:6379/0")).toThrow(
      /must not include credentials/,
    );
    expect(() => validatePiAgentRedisURLForStorage("rediss://redis.internal:6379/0?password=secret")).toThrow(
      /must not include credentials/,
    );
  });

  it("redacts legacy Redis credentials before returning connection docs", () => {
    const connection: PiAgentConnectionDoc = {
      id: "pi",
      displayName: "Pi",
      mode: "relayLink",
      status: "online",
      redisURL: "redis://user:secret@redis.internal:6379/0",
      capabilities: [],
      createdAt: "2026-06-01T00:00:00.000Z",
      updatedAt: "2026-06-01T00:00:00.000Z",
      schemaVersion: 1,
    };

    const redacted = redactPiAgentConnectionDoc(connection);

    expect(redacted.redisURL).toBe("redis://[REDACTED]@redis.internal:6379/0");
    expect(JSON.stringify(redacted)).not.toContain("secret");
  });

  it("redacts unparsable legacy Redis values entirely", () => {
    expect(redactPiAgentRedisURL("not a redis url with password=secret")).toBe("[REDACTED]");
  });
});
