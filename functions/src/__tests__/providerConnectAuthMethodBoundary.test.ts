import { describe, expect, it } from "vitest";

import { normalizeCloudConnectAuthMethodID } from "../callables/shared.js";

describe("provider account cloud auth method boundary", () => {
  it("allows known methods and legacy missing metadata", () => {
    expect(normalizeCloudConnectAuthMethodID("openai", undefined, "sk-proj-test-key")).toBeUndefined();
    expect(normalizeCloudConnectAuthMethodID("openai", " openai-api-key ")).toBe("openai-api-key");
    expect(normalizeCloudConnectAuthMethodID("openai", " openai-admin-key ")).toBe("openai-admin-key");
  });

  it("stamps known non-routing quota credentials when older clients omit method metadata", () => {
    expect(normalizeCloudConnectAuthMethodID("openai", undefined, "sk-admin-test-key")).toBe("openai-admin-key");
    expect(normalizeCloudConnectAuthMethodID("xai", undefined, "xai-mgmt-test-key")).toBe("xai-management-key");
    expect(normalizeCloudConnectAuthMethodID("kimi", undefined, "sk-kimi-test-key")).toBe("moonshot-api-key");
  });

  it("rejects unsupported explicit method ids for known providers", () => {
    expect(() => normalizeCloudConnectAuthMethodID("openai", "openai-not-real")).toThrow(
      /Unsupported provider credential method/,
    );
  });
});
