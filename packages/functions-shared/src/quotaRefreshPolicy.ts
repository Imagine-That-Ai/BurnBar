export enum QuotaSignalTier {
  TrafficHeaders = 0,
  LocalArtifact = 1,
  CachedSnapshot = 2,
  StatusEndpoint = 3,
  ServerSweep = 4,
  SpendProbe = 5,
}

type QuotaRefreshWindowKind =
  | "rollingHours"
  | "rollingDays"
  | "daily"
  | "weekly"
  | "monthly"
  | "lifetime"
  | "custom";

interface QuotaRefreshPolicySnapshot {
  fetchedAt: Date | string | number;
  remainingFraction?: number | null;
  windowKind: QuotaRefreshWindowKind;
  resetsAt?: Date | string | number | null;
}

const MINIMUM_TTL_SECONDS = 60;
const MAXIMUM_TTL_SECONDS = 4 * 60 * 60;
const HIGH_REMAINING_TTL_SECONDS = 30 * 60;
const MEDIUM_REMAINING_TTL_SECONDS = 10 * 60;
const LOW_REMAINING_TTL_SECONDS = 3 * 60;
const UNKNOWN_REMAINING_TTL_SECONDS = 15 * 60;
const DEFAULT_DAILY_PROBE_BUDGET = 4;

export const QuotaRefreshPolicy = {
  minimumTTLSeconds: MINIMUM_TTL_SECONDS,
  maximumTTLSeconds: MAXIMUM_TTL_SECONDS,
  highRemainingTTLSeconds: HIGH_REMAINING_TTL_SECONDS,
  mediumRemainingTTLSeconds: MEDIUM_REMAINING_TTL_SECONDS,
  lowRemainingTTLSeconds: LOW_REMAINING_TTL_SECONDS,
  unknownRemainingTTLSeconds: UNKNOWN_REMAINING_TTL_SECONDS,
  defaultDailyProbeBudget: DEFAULT_DAILY_PROBE_BUDGET,

  adaptiveTTL(
    remainingFraction: number | null | undefined,
    _windowKind: QuotaRefreshWindowKind,
    resetsAt: Date | string | number | null | undefined,
    now: Date = new Date(),
  ): number {
    let baseTTL: number;
    if (typeof remainingFraction === "number" && Number.isFinite(remainingFraction)) {
      const clamped = Math.min(Math.max(remainingFraction, 0), 1);
      if (clamped >= 0.5) {
        baseTTL = HIGH_REMAINING_TTL_SECONDS;
      } else if (clamped >= 0.2) {
        baseTTL = MEDIUM_REMAINING_TTL_SECONDS;
      } else {
        baseTTL = LOW_REMAINING_TTL_SECONDS;
      }
    } else {
      baseTTL = UNKNOWN_REMAINING_TTL_SECONDS;
    }

    const parsedResetsAt = parseDate(resetsAt);
    const resetBound =
      parsedResetsAt === undefined
        ? MAXIMUM_TTL_SECONDS
        : Math.max(
            MINIMUM_TTL_SECONDS,
            Math.min(MAXIMUM_TTL_SECONDS, (parsedResetsAt.getTime() - now.getTime()) / 1000),
          );
    return Math.min(Math.max(baseTTL, MINIMUM_TTL_SECONDS), resetBound);
  },

  shouldSpendProbe(
    lastProbeAt: Date | string | number | null | undefined,
    probesToday: number,
    dailyProbeBudget = DEFAULT_DAILY_PROBE_BUDGET,
    now: Date = new Date(),
  ): boolean {
    if (dailyProbeBudget <= 0) return false;
    if (probesToday < 0 || probesToday >= dailyProbeBudget) return false;
    const parsedLastProbeAt = parseDate(lastProbeAt);
    if (parsedLastProbeAt !== undefined && parsedLastProbeAt.getTime() > now.getTime()) {
      return false;
    }
    return true;
  },

  nextRefreshAfter(snapshot: QuotaRefreshPolicySnapshot, now: Date = new Date()): Date {
    const fetchedAt = parseRequiredDate(snapshot.fetchedAt, "fetchedAt");
    const ttlSeconds = QuotaRefreshPolicy.adaptiveTTL(
      snapshot.remainingFraction,
      snapshot.windowKind,
      snapshot.resetsAt,
      now,
    );
    return new Date(fetchedAt.getTime() + ttlSeconds * 1000);
  },
};

function parseDate(value: Date | string | number | null | undefined): Date | undefined {
  if (value === null || value === undefined) return undefined;
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) return undefined;
  return date;
}

function parseRequiredDate(value: Date | string | number, fieldName: string): Date {
  const date = parseDate(value);
  if (!date) {
    throw new Error(`Invalid ${fieldName} date`);
  }
  return date;
}
