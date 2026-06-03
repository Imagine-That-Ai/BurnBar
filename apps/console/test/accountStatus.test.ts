import { describe, expect, it } from "vitest";

import {
  hasPublishedAccountData,
  isFirstRunAccount,
  usageTotals,
} from "../lib/accountStatus";
import type { DataDomainUsageResponse } from "../lib/api";

function usageResponse(
  override: Partial<DataDomainUsageResponse> = {},
): DataDomainUsageResponse {
  return {
    ok: true,
    tier: "free",
    account: {
      profile: { state: "missing" },
      hasPublishedData: false,
      totalCount: 0,
      totalBytes: 0,
    },
    limits: { pensieve: { sources: 1, chunks: 1, bytes: 1 } },
    domains: [],
    schemaVersion: 1,
    ...override,
  };
}

describe("accountStatus", () => {
  it("sums domain usage for the homepage figures", () => {
    expect(
      usageTotals(
        usageResponse({
          domains: [
            { id: "usage_spend", count: 2, bytes: 0 },
            { id: "pensieve", count: 3, bytes: 4096 },
          ],
        }),
      ),
    ).toEqual({ count: 5, bytes: 4096 });
  });

  it("detects a signed-in first-run account", () => {
    const data = usageResponse();

    expect(hasPublishedAccountData(data)).toBe(false);
    expect(isFirstRunAccount(data)).toBe(true);
  });

  it("treats a legacy zero-total usage response as a first-run account", () => {
    const { account: _account, ...legacyData } = usageResponse();

    expect(isFirstRunAccount(legacyData)).toBe(true);
  });

  it("treats either a cloud profile or domain usage as published data", () => {
    expect(
      isFirstRunAccount(
        usageResponse({
          account: {
            profile: { state: "published", sourceDeviceId: "macbook" },
            hasPublishedData: true,
            totalCount: 0,
            totalBytes: 0,
          },
        }),
      ),
    ).toBe(false);

    expect(
      isFirstRunAccount(
        usageResponse({
          domains: [{ id: "provider_accounts", count: 1, bytes: 0 }],
        }),
      ),
    ).toBe(false);
  });
});
