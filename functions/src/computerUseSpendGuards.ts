/**
 * @fileoverview Defense-in-depth clamps for owner-writable Computer Use spend headers.
 *
 * The Mac writes action headers under `users/{uid}/computer_use_actions/*`.
 * Scheduled Functions may aggregate those headers, but a single owner-written
 * document must not be able to force the global Computer Use budget kill switch.
 */

const DEFAULT_ACTION_SPEND_CEILING_USD = 0.25;
const DEFAULT_USER_DAILY_SPEND_CEILING_USD = 5;

export interface ComputerUseSpendInput {
  uid: string;
  visionTokensCostUSD: number | undefined;
}

export function ownerWritableComputerUseActionSpendCeilingUSD(): number {
  return positiveNumberEnv("COMPUTER_USE_OWNER_ACTION_SPEND_CEILING_USD", DEFAULT_ACTION_SPEND_CEILING_USD);
}

export function ownerWritableComputerUseUserDailySpendCeilingUSD(): number {
  return positiveNumberEnv("COMPUTER_USE_OWNER_DAILY_SPEND_CEILING_USD", DEFAULT_USER_DAILY_SPEND_CEILING_USD);
}

export function trustedComputerUseActionSpendUSD(raw: unknown): number {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return 0;
  return Math.min(parsed, ownerWritableComputerUseActionSpendCeilingUSD());
}

export function trustedComputerUseSpendByUser(inputs: ComputerUseSpendInput[]): Map<string, number> {
  const perUser = new Map<string, number>();
  const dailyCeiling = ownerWritableComputerUseUserDailySpendCeilingUSD();
  for (const input of inputs) {
    const uid = input.uid.trim();
    if (!uid) continue;
    const current = perUser.get(uid) ?? 0;
    perUser.set(uid, Math.min(dailyCeiling, current + trustedComputerUseActionSpendUSD(input.visionTokensCostUSD)));
  }
  return perUser;
}

export function trustedComputerUseTotalSpendUSD(inputs: ComputerUseSpendInput[]): number {
  let total = 0;
  for (const value of trustedComputerUseSpendByUser(inputs).values()) {
    total += value;
  }
  return Math.round(total * 100) / 100;
}

function positiveNumberEnv(name: string, fallback: number): number {
  const raw = (process.env[name] ?? "").trim();
  if (!raw) return fallback;
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return parsed;
}

