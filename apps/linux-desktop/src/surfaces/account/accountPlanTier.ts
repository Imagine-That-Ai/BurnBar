import type { AccountStatus } from '../../tauriBridge.js';

export type AccountPlanTier = 'local' | 'cloud' | 'unknown';

export const PLAN_TIER_LABEL: Record<AccountPlanTier, string> = {
  local: 'Local',
  cloud: 'Cloud',
  unknown: 'Unknown'
};

export function accountPlanTier(status: AccountStatus): AccountPlanTier {
  if (!status.signedIn) return 'local';
  if (status.syncState === 'active' || status.syncState === 'paused') return 'cloud';
  return 'unknown';
}