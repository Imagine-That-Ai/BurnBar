/**
 * Linux proxy-route status contracts shared by the daemon bridge and fixtures.
 * Wire names mirror BurnBarRPC; unknown values fail closed for forward
 * compatibility instead of leaking an unrecognized status to the UI.
 */
export type ProxyRouteFinalStatus =
  | 'exact'
  | 'same_model_failover'
  | 'cross_vendor_fallback'
  | 'failed'
  | 'rejected'
  | 'interrupted'
  | 'unknown';

const PROXY_ROUTE_FINAL_STATUSES: readonly ProxyRouteFinalStatus[] = [
  'exact',
  'same_model_failover',
  'cross_vendor_fallback',
  'failed',
  'rejected',
  'interrupted'
];

export function normalizeProxyRouteFinalStatus(raw: string): ProxyRouteFinalStatus {
  return (PROXY_ROUTE_FINAL_STATUSES as readonly string[]).includes(raw)
    ? (raw as ProxyRouteFinalStatus)
    : 'unknown';
}

/** Exhaustive labels keep new wire statuses from rendering raw names. */
export const PROXY_ROUTE_FINAL_STATUS_COPY: Record<ProxyRouteFinalStatus, string> = {
  exact: 'Exact',
  same_model_failover: 'Same model failover',
  cross_vendor_fallback: 'Cross-vendor fallback',
  failed: 'Failed',
  rejected: 'No route',
  interrupted: 'Interrupted — retryable',
  unknown: 'Unknown status'
};
