import { describe, expect, it } from "vitest";

import {
  CLOUD_FEATURE_ABUSE_DAILY_REFRESH_LIMIT,
  CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE,
  REQUIRED_SUSPENDED_USER_DENIED_SURFACES,
  cloudFeatureSuspensionDeniesSurface,
  cloudFeatureSuspensionPath,
  parseCloudFeatureSuspension,
} from "../cloudFeatureSuspensions.js";

describe("cloudFeatureSuspensions", () => {
  it("uses the launch-plan suspension document path", () => {
    expect(CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE).toBe("users/{uid}/ops/suspensions/cloudFeatures/current");
    expect(cloudFeatureSuspensionPath("user_123")).toBe("users/user_123/ops/suspensions/cloudFeatures/current");
    expect(cloudFeatureSuspensionPath("user_123").split("/")).toHaveLength(6);
  });

  it("defaults active suspensions to every required denied surface and a five-refresh hosted quota limit", () => {
    const suspension = parseCloudFeatureSuspension({ active: true }, Date.now());

    expect(suspension?.userQuotaDailyRefreshLimit).toBe(CLOUD_FEATURE_ABUSE_DAILY_REFRESH_LIMIT);
    for (const surface of REQUIRED_SUSPENDED_USER_DENIED_SURFACES) {
      expect(suspension?.deniedSurfaces).toContain(surface);
      expect(cloudFeatureSuspensionDeniesSurface(suspension, surface)).toBe(true);
    }
  });

  it("honors inactive, expired, custom-surface, and custom-limit overrides", () => {
    expect(parseCloudFeatureSuspension({ active: false })).toBeNull();
    expect(parseCloudFeatureSuspension({ active: true, expiresAt: "2020-01-01T00:00:00Z" }, Date.now())).toBeNull();

    const suspension = parseCloudFeatureSuspension({
      active: true,
      deniedSurfaces: ["remote_mcp"],
      userQuotaDailyRefreshLimit: 7,
    });

    expect(suspension?.userQuotaDailyRefreshLimit).toBe(7);
    expect(cloudFeatureSuspensionDeniesSurface(suspension, "remote_mcp")).toBe(true);
    expect(cloudFeatureSuspensionDeniesSurface(suspension, "hosted_quota")).toBe(false);
  });
});
