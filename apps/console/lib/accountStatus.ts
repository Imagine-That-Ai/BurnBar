import type { DataDomainUsageResponse } from "./api";

export interface UsageTotals {
  count: number;
  bytes: number;
}

export function usageTotals(data: DataDomainUsageResponse | null | undefined): UsageTotals {
  return (data?.domains ?? []).reduce(
    (acc, domain) => ({
      count: acc.count + domain.count,
      bytes: acc.bytes + domain.bytes,
    }),
    { count: 0, bytes: 0 },
  );
}

export function hasPublishedAccountData(
  data: DataDomainUsageResponse | null | undefined,
): boolean {
  if (!data) return false;
  const totals = usageTotals(data);
  return Boolean(
    data.account?.hasPublishedData ||
      data.account?.profile.state === "published" ||
      totals.count > 0 ||
      totals.bytes > 0,
  );
}

export function isFirstRunAccount(data: DataDomainUsageResponse | null | undefined): boolean {
  return Boolean(data) && !hasPublishedAccountData(data);
}
