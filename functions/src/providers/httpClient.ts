/**
 * Resilient HTTP for provider quota adapters.
 * All outbound provider API calls must go through providerFetch.
 */

import { resilientFetch } from "../resilienceHelpers.js";

export function providerFetch(
  provider: string,
  operation: string,
  url: string | URL,
  init?: RequestInit,
): Promise<Response> {
  return resilientFetch(`${provider}.${operation}`, url, init);
}
